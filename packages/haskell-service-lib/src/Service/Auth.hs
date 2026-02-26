{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Service.Auth
  ( AccessTokenClaims (..),
    JwtAccessClaims (..),
    JWTAuthConfig (..),
    makeJWTAuthConfig,
    jwtPrincipalExtractor,
    -- Servant combinators
    JWTAuth,
    HasScopes,
    Authorize,
    -- Request-level policy types (used inside Authorize '[...])
    IsOwner,
    HasScope,
    -- Policy typeclasses (advanced use)
    RequestCheck (..),
    AnyCheck (..),
    -- Helpers
    KnownSymbols (..),
  )
where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Crypto.JOSE.JWK (JWK)
import Crypto.JWT
  ( ClaimsSet,
    HasClaimsSet (..),
    JWTError,
    SignedJWT,
    claimJti,
    claimSub,
    decodeCompact,
    defaultJWTValidationSettings,
    verifyClaims,
  )
import Crypto.Random (MonadRandom (..))
import Data.Aeson
  ( FromJSON (..),
    Result (..),
    ToJSON,
    Value (Object, String),
    fromJSON,
    object,
    toJSON,
    withObject,
    (.=),
    (.:?),
  )
import Data.Kind (Type)
import Data.List (find)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Typeable (typeRep)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Network.Wai (Request, requestHeaders)
import RIO
import RIO.Text (pack)
import Servant
  ( FromHttpApiData (..),
    HasServer (..),
    type (:>),
    err400,
    err401,
    err403,
  )
import Servant.Server.Internal
  ( CaptureHint (..),
    Router' (CaptureRouter),
    DelayedIO,
    addAuthCheck,
    addCapture,
    delayedFail,
    delayedFailFatal,
    withRequest,
  )
import Servant.Server (HasContextEntry (..), errBody, getContextEntry)

-- Orphan instance: crypton does not provide MonadRandom for ExceptT.
instance MonadRandom m => MonadRandom (ExceptT e m) where
  getRandomBytes n = lift (getRandomBytes n)

-- | Claims extracted from a verified access token.
data AccessTokenClaims = AccessTokenClaims
  { atcSubject :: Text,
    atcEmail :: (Maybe Text),
    atcJti :: Text,
    atcScopes :: [Text]
  }
  deriving (Show, Eq)

-- | jose claims subtype for access tokens.
-- Used with signClaims for issuance and as a FromJSON target for verification.
data JwtAccessClaims = JwtAccessClaims
  { jacClaimsSet :: ClaimsSet,
    jacType :: (Maybe Text),
    jacEmail :: (Maybe Text),
    jacScopes :: (Maybe [Text])
  }

instance HasClaimsSet JwtAccessClaims where
  claimsSet f jac =
    fmap (\cs -> jac {jacClaimsSet = cs}) (f (jacClaimsSet jac))

instance FromJSON JwtAccessClaims where
  parseJSON = withObject "JwtAccessClaims" $ \o ->
    JwtAccessClaims
      <$> parseJSON (Object o)
      <*> o .:? "type"
      <*> o .:? "email"
      <*> o .:? "scopes"

instance ToJSON JwtAccessClaims where
  toJSON jac = mergeObjects
    (toJSON (jacClaimsSet jac))
    (object $ catMaybes
      [ fmap ("type" .=) (jacType jac)
      , fmap ("email" .=) (jacEmail jac)
      , fmap ("scopes" .=) (jacScopes jac)
      ])
    where
      mergeObjects (Object a) (Object b) = Object (a <> b)
      mergeObjects a _ = a

-- | Config injected via Servant context for JWT validation.
data JWTAuthConfig = JWTAuthConfig
  { jwtAuthValidate :: Text -> IO (Either Text AccessTokenClaims),
    jwtAuthSubjectPrefix :: Text
  }

-- | Build a JWTAuthConfig from a JWK and subject prefix.
makeJWTAuthConfig :: JWK -> Text -> JWTAuthConfig
makeJWTAuthConfig key prefix =
  JWTAuthConfig
    { jwtAuthValidate = verifyToken key,
      jwtAuthSubjectPrefix = prefix
    }

verifyToken :: JWK -> Text -> IO (Either Text AccessTokenClaims)
verifyToken key tokenText = do
  let tokenBs = BL.fromStrict $ encodeUtf8 tokenText
  result <- runExceptT $ do
    (signedJwt :: SignedJWT) <- decodeCompact tokenBs
    verifyClaims (defaultJWTValidationSettings (const True)) key signedJwt
  case result of
    Left (err :: JWTError) -> return $ Left (pack $ show err)
    Right claims -> return $ extractClaims claims

-- | Extract AccessTokenClaims from a verified ClaimsSet.
-- Custom fields (email, scopes) are recovered via a JSON round-trip
-- into JwtAccessClaims, avoiding the deprecated unregisteredClaims lens.
extractClaims :: ClaimsSet -> Either Text AccessTokenClaims
extractClaims claims = do
  sub <- maybe (Left "Missing sub") (Right . suriToText) (claims ^. claimSub)
  jti <- maybe (Left "Missing jti") (Right . suriToText) (claims ^. claimJti)
  jac <- case fromJSON (toJSON claims) :: Result JwtAccessClaims of
    Error err -> Left (pack err)
    Success j -> Right j
  let email = jacEmail jac
      scopes = fromMaybe [] (jacScopes jac)
  Right AccessTokenClaims {atcSubject = sub, atcEmail = email, atcJti = jti, atcScopes = scopes}

suriToText :: (ToJSON a) => a -> Text
suriToText suri = case toJSON suri of
  String t -> t
  other -> pack $ show other

extractBearer :: Request -> Maybe Text
extractBearer req =
  case find ((== "Authorization") . fst) (requestHeaders req) of
    Just (_, v)
      | "Bearer " `BS.isPrefixOf` v -> Just (decodeUtf8Lenient (BS.drop 7 v))
    _ -> Nothing

-- | Extract the JWT subject (user ID) from a request for logging purposes.
--
-- Decodes and verifies the Bearer token but does not fail — returns 'Nothing'
-- for anonymous requests or invalid tokens.  Intended for use with
-- 'Service.CorrelationId.requestLoggingMiddleware'.
jwtPrincipalExtractor :: JWTAuthConfig -> Request -> IO (Maybe Text)
jwtPrincipalExtractor cfg req =
  case extractBearer req of
    Nothing -> return Nothing
    Just token ->
      fmap (either (const Nothing) (Just . atcSubject)) (jwtAuthValidate cfg token)

-- ============================================================================
-- JWTAuth combinator — validates Bearer JWT, no scope/ownership check
-- ============================================================================

-- | Servant combinator: validates Bearer JWT, provides AccessTokenClaims to handler.
data JWTAuth

instance
  (HasServer api ctx, HasContextEntry ctx JWTAuthConfig) =>
  HasServer (JWTAuth :> api) ctx
  where
  type ServerT (JWTAuth :> api) m = AccessTokenClaims -> ServerT api m

  hoistServerWithContext _ pc nt s =
    hoistServerWithContext (Proxy @api) pc nt . s

  route Proxy ctx sub =
    route (Proxy @api) ctx (sub `addAuthCheck` authCheck)
    where
      cfg = getContextEntry ctx :: JWTAuthConfig
      authCheck :: DelayedIO AccessTokenClaims
      authCheck = withRequest $ \req ->
        case extractBearer req of
          Nothing -> delayedFailFatal err401
          Just token ->
            liftIO (jwtAuthValidate cfg token) >>= \case
              Left _ -> delayedFailFatal err401
              Right claims -> return claims

-- ============================================================================
-- HasScopes combinator — validates JWT and enforces required scopes
-- ============================================================================

-- | Servant combinator: validates Bearer JWT and enforces that the token's
-- scopes include all of @required@. Passes 'AccessTokenClaims' to the handler.
data HasScopes (required :: [Symbol])

instance
  ( HasServer api ctx,
    HasContextEntry ctx JWTAuthConfig,
    KnownSymbols required
  ) =>
  HasServer (HasScopes required :> api) ctx
  where
  type ServerT (HasScopes required :> api) m = AccessTokenClaims -> ServerT api m

  hoistServerWithContext _ pc nt s =
    hoistServerWithContext (Proxy @api) pc nt . s

  route Proxy ctx sub =
    route (Proxy @api) ctx (sub `addAuthCheck` authCheck)
    where
      cfg = getContextEntry ctx :: JWTAuthConfig
      required = map pack $ symbolVals (Proxy @required)
      authCheck :: DelayedIO AccessTokenClaims
      authCheck = withRequest $ \req ->
        case extractBearer req of
          Nothing -> delayedFailFatal err401
          Just token ->
            liftIO (jwtAuthValidate cfg token) >>= \case
              Left _ -> delayedFailFatal err401
              Right claims ->
                if all (`elem` atcScopes claims) required
                  then return claims
                  else delayedFailFatal err403 {errBody = "Insufficient scopes"}

-- ============================================================================
-- Composable request-level policy system
-- ============================================================================
--
-- Usage:
--
--   -- Allow owner OR admin:
--   :> Authorize "id" Int64 '[IsOwner, HasScope "admin"]
--
--   -- Allow any authenticated user (no ownership check):
--   :> JWTAuth :> Capture "id" Int64
--
-- The @Authorize@ combinator checks each policy in the list and grants access
-- if ANY one passes (OR semantics). All policies are evaluated purely from
-- request data (JWT claims + URL parameter) — no DB access.
--
-- For resource-level authorization (where you need to fetch the resource first),
-- use 'Service.Policy.authorize' in the domain layer after fetching the resource.

-- | Request-level policy: the captured URL parameter (shown as a string)
-- concatenated with the JWT subject prefix must equal the JWT subject.
-- Use this when the URL parameter IS the resource owner's user ID.
--
-- Example: @GET /users/42@ with a token whose subject is @"user-42"@.
data IsOwner

-- | Request-level policy: the JWT must carry the given scope.
-- Example: @HasScope "admin"@ passes if @"admin" `elem` atcScopes claims@.
data HasScope (s :: Symbol)

-- | Typeclass for evaluating a single request-level policy.
class RequestCheck (p :: Type) t where
  checkRequest :: Proxy p -> JWTAuthConfig -> t -> AccessTokenClaims -> Bool

instance Show t => RequestCheck IsOwner t where
  checkRequest _ cfg v claims =
    jwtAuthSubjectPrefix cfg <> pack (show v) == atcSubject claims

instance KnownSymbol s => RequestCheck (HasScope s) t where
  checkRequest _ _ _ claims =
    pack (symbolVal (Proxy @s)) `elem` atcScopes claims

-- | Typeclass for evaluating a list of policies with OR semantics:
-- access is granted if ANY policy in the list passes.
class AnyCheck (ps :: [Type]) t where
  anyCheck :: Proxy ps -> JWTAuthConfig -> t -> AccessTokenClaims -> Bool

instance AnyCheck '[] t where
  anyCheck _ _ _ _ = False

instance (RequestCheck p t, AnyCheck ps t) => AnyCheck (p ': ps) t where
  anyCheck _ cfg v claims =
    checkRequest (Proxy @p) cfg v claims
      || anyCheck (Proxy @ps) cfg v claims

-- | Servant combinator: captures a path parameter, validates the Bearer JWT,
-- and grants access if ANY policy in @policies@ passes.
--
-- On success, passes @(capturedValue, AccessTokenClaims)@ to the handler.
-- Returns 401 for missing/invalid tokens, 403 if no policy passes.
data Authorize (sym :: Symbol) t (policies :: [Type])

instance
  ( HasServer api ctx,
    HasContextEntry ctx JWTAuthConfig,
    KnownSymbol sym,
    FromHttpApiData t,
    Show t,
    Typeable t,
    AnyCheck policies t
  ) =>
  HasServer (Authorize sym t policies :> api) ctx
  where
  type ServerT (Authorize sym t policies :> api) m = t -> AccessTokenClaims -> ServerT api m

  hoistServerWithContext _ pc nt s =
    \v c -> hoistServerWithContext (Proxy @api) pc nt (s v c)

  route Proxy ctx sub =
    CaptureRouter [hint] $
      route (Proxy @api) ctx $
        addCapture (fmap (\f (v, c) -> f v c) sub) $ \txt -> do
          v <- either (\_ -> delayedFail err400) return (parseUrlPiece txt)
          claims <- withRequest $ \req ->
            case extractBearer req of
              Nothing -> delayedFailFatal err401
              Just token ->
                liftIO (jwtAuthValidate cfg token) >>= \case
                  Left _ -> delayedFailFatal err401
                  Right c -> return c
          unless (anyCheck (Proxy @policies) cfg v claims) $
            delayedFailFatal err403 {errBody = "Forbidden"}
          return (v, claims)
    where
      cfg = getContextEntry ctx :: JWTAuthConfig
      hint = CaptureHint (pack $ symbolVal (Proxy @sym)) (typeRep (Proxy @t))

-- ============================================================================
-- Helpers
-- ============================================================================

-- | Reflect a type-level list of Symbols to a value-level list of Strings.
class KnownSymbols (syms :: [Symbol]) where
  symbolVals :: Proxy syms -> [String]

instance KnownSymbols '[] where
  symbolVals _ = []

instance (KnownSymbol s, KnownSymbols ss) => KnownSymbols (s ': ss) where
  symbolVals _ = symbolVal (Proxy @s) : symbolVals (Proxy @ss)
