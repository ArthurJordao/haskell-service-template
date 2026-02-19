{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Service.Auth
  ( AccessTokenClaims (..),
    JwtAccessClaims (..),
    JWTAuthConfig (..),
    makeJWTAuthConfig,
    JWTAuth,
    RequireOwner,
    RequireOwnerOrScopes,
    HasScopes,
    KnownSymbols (..),
  )
where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Crypto.JOSE.JWK (JWK, fromOctets)
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
  { atcSubject :: !Text,
    atcEmail :: !(Maybe Text),
    atcJti :: !Text,
    atcScopes :: ![Text]
  }
  deriving (Show, Eq)

-- | jose claims subtype for access tokens.
-- Used with signClaims for issuance and as a FromJSON target for verification.
data JwtAccessClaims = JwtAccessClaims
  { jacClaimsSet :: !ClaimsSet,
    jacType :: !(Maybe Text),
    jacEmail :: !(Maybe Text),
    jacScopes :: !(Maybe [Text])
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

-- | Build a JWTAuthConfig from a raw HMAC secret and subject prefix.
makeJWTAuthConfig :: ByteString -> Text -> JWTAuthConfig
makeJWTAuthConfig secret prefix =
  JWTAuthConfig
    { jwtAuthValidate = verifyToken (fromOctets secret),
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

-- | Servant combinator: captures a path param, validates JWT, and enforces ownership.
data RequireOwner (sym :: Symbol) t

instance
  ( HasServer api ctx,
    HasContextEntry ctx JWTAuthConfig,
    KnownSymbol sym,
    FromHttpApiData t,
    Show t,
    Typeable t
  ) =>
  HasServer (RequireOwner sym t :> api) ctx
  where
  type ServerT (RequireOwner sym t :> api) m = t -> AccessTokenClaims -> ServerT api m

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
          let expected = jwtAuthSubjectPrefix cfg <> pack (show v)
          when (expected /= atcSubject claims) $
            delayedFailFatal err403 {errBody = "Forbidden"}
          return (v, claims)
    where
      cfg = getContextEntry ctx :: JWTAuthConfig
      hint = CaptureHint (pack $ symbolVal (Proxy @sym)) (typeRep (Proxy @t))

-- | Servant combinator: like 'RequireOwner', but also accepts tokens that carry
-- at least one of the @override@ scopes (e.g. @'["admin"]@).
data RequireOwnerOrScopes (sym :: Symbol) t (override :: [Symbol])

instance
  ( HasServer api ctx,
    HasContextEntry ctx JWTAuthConfig,
    KnownSymbol sym,
    FromHttpApiData t,
    Show t,
    Typeable t,
    KnownSymbols override
  ) =>
  HasServer (RequireOwnerOrScopes sym t override :> api) ctx
  where
  type ServerT (RequireOwnerOrScopes sym t override :> api) m = t -> AccessTokenClaims -> ServerT api m

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
          let expected = jwtAuthSubjectPrefix cfg <> pack (show v)
              overrideScopes = map pack $ symbolVals (Proxy @override)
              hasOverride = any (`elem` atcScopes claims) overrideScopes
          unless (expected == atcSubject claims || hasOverride) $
            delayedFailFatal err403 {errBody = "Forbidden"}
          return (v, claims)
    where
      cfg = getContextEntry ctx :: JWTAuthConfig
      hint = CaptureHint (pack $ symbolVal (Proxy @sym)) (typeRep (Proxy @t))

-- | Reflect a type-level list of Symbols to a value-level list of Strings.
class KnownSymbols (syms :: [Symbol]) where
  symbolVals :: Proxy syms -> [String]

instance KnownSymbols '[] where
  symbolVals _ = []

instance (KnownSymbol s, KnownSymbols ss) => KnownSymbols (s ': ss) where
  symbolVals _ = symbolVal (Proxy @s) : symbolVals (Proxy @ss)

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
