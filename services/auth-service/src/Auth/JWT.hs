{-# OPTIONS_GHC -Wno-orphans #-}

module Auth.JWT
  ( JWTSettings (..),
    AccessTokenClaims (..),
    makeJWTKey,
    issueAccessToken,
    issueRefreshToken,
    verifyAccessToken,
    verifyRefreshTokenJti,
  )
where

import Service.Auth (AccessTokenClaims (..))

import Control.Monad.Except (runExceptT)
import Crypto.JOSE (encodeCompact)
import Crypto.JOSE.JWK (JWK, fromOctets)
import Crypto.JWT
  ( ClaimsSet,
    JWTError,
    NumericDate (..),
    SignedJWT,
    claimExp,
    claimIat,
    claimJti,
    claimSub,
    decodeCompact,
    defaultJWTValidationSettings,
    emptyClaimsSet,
    newJWSHeader,
    signClaims,
    unregisteredClaims,
    verifyClaims,
  )
import Crypto.JOSE.JWA.JWS (Alg (HS256))
import Data.Aeson (Result (..), ToJSON, Value (String), fromJSON, toJSON)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, nominalDay)
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import Lens.Micro ((?~))
import RIO
import RIO.Text (pack, unpack)

-- | Configuration for JWT issuance and validation.
data JWTSettings = JWTSettings
  { jwtKey :: !JWK,
    -- | Access token lifetime in seconds (e.g. 900 = 15 min).
    jwtAccessTokenExpirySeconds :: !Int,
    -- | Refresh token lifetime in days (e.g. 7 = 7 days).
    jwtRefreshTokenExpiryDays :: !Int
  }

accessExpiry :: JWTSettings -> NominalDiffTime
accessExpiry = fromIntegral . jwtAccessTokenExpirySeconds

refreshExpiry :: JWTSettings -> NominalDiffTime
refreshExpiry s = nominalDay * fromIntegral (jwtRefreshTokenExpiryDays s)

-- | Create a symmetric JWK from a raw secret.
makeJWTKey :: ByteString -> JWK
makeJWTKey = fromOctets

generateJti :: IO Text
generateJti = UUID.toText <$> nextRandom

defaultUserScopes :: [Text]
defaultUserScopes = ["read:accounts:own", "write:accounts:own"]

-- | Issue a signed access JWT. Returns compact-encoded token text.
issueAccessToken :: JWTSettings -> Int64 -> Text -> UTCTime -> IO (Either Text Text)
issueAccessToken settings userId email issuedAt = do
  jti <- generateJti
  let expiry = addUTCTime (accessExpiry settings) issuedAt
      sub = fromString ("user-" <> show userId)
      claims =
        emptyClaimsSet
          & claimSub ?~ sub
          & claimIat ?~ NumericDate issuedAt
          & claimExp ?~ NumericDate expiry
          & claimJti ?~ fromString (unpack jti)
          & unregisteredClaims
            .~ Map.fromList
              [ ("type", String "customer"),
                ("email", String email),
                ("scopes", toJSON defaultUserScopes)
              ]
  result <- runExceptT $ signClaims (jwtKey settings) (newJWSHeader ((), HS256)) claims
  case result of
    Left (err :: JWTError) -> return $ Left (pack $ show err)
    Right jwt -> return $ Right $ decodeUtf8Lenient $ BL.toStrict $ encodeCompact jwt

-- | Issue a signed refresh JWT. Returns (jti, compactTokenText).
issueRefreshToken :: JWTSettings -> Int64 -> UTCTime -> IO (Either Text (Text, Text))
issueRefreshToken settings userId issuedAt = do
  jti <- generateJti
  let expiry = addUTCTime (refreshExpiry settings) issuedAt
      sub = fromString ("user-" <> show userId)
      claims =
        emptyClaimsSet
          & claimSub ?~ sub
          & claimIat ?~ NumericDate issuedAt
          & claimExp ?~ NumericDate expiry
          & claimJti ?~ fromString (unpack jti)
          & unregisteredClaims
            .~ Map.fromList [("type", String "refresh")]
  result <- runExceptT $ signClaims (jwtKey settings) (newJWSHeader ((), HS256)) claims
  case result of
    Left (err :: JWTError) -> return $ Left (pack $ show err)
    Right jwt ->
      return $
        Right (jti, decodeUtf8Lenient $ BL.toStrict $ encodeCompact jwt)

-- | Verify an access token and extract typed claims.
verifyAccessToken :: JWTSettings -> Text -> IO (Either Text AccessTokenClaims)
verifyAccessToken settings tokenText = do
  let tokenBs = BL.fromStrict $ encodeUtf8 tokenText
  result <- runExceptT $ do
    (signedJwt :: SignedJWT) <- decodeCompact tokenBs
    verifyClaims (defaultJWTValidationSettings (const True)) (jwtKey settings) signedJwt
  case result of
    Left (err :: JWTError) -> return $ Left (pack $ show err)
    Right claims -> return $ extractAccessClaims claims

-- | Verify a refresh token and return its JTI for DB revocation check.
verifyRefreshTokenJti :: JWTSettings -> Text -> IO (Either Text Text)
verifyRefreshTokenJti settings tokenText = do
  let tokenBs = BL.fromStrict $ encodeUtf8 tokenText
  result <- runExceptT $ do
    (signedJwt :: SignedJWT) <- decodeCompact tokenBs
    verifyClaims (defaultJWTValidationSettings (const True)) (jwtKey settings) signedJwt
  case result of
    Left (err :: JWTError) -> return $ Left (pack $ show err)
    Right claims ->
      return $ case claims ^. claimJti of
        Nothing -> Left "Missing jti in refresh token"
        Just jtiSuri -> Right (suriToText jtiSuri)

-- | Extract typed claims from a raw ClaimsSet.
extractAccessClaims :: ClaimsSet -> Either Text AccessTokenClaims
extractAccessClaims claims = do
  sub <- maybe (Left "Missing sub claim") (Right . suriToText) (claims ^. claimSub)
  jti <- maybe (Left "Missing jti claim") (Right . suriToText) (claims ^. claimJti)
  let extra = claims ^. unregisteredClaims
  email <- lookupText "email" extra
  let scopes = case Map.lookup "scopes" extra of
        Just v -> case fromJSON v of
          Success (s :: [Text]) -> s
          _ -> defaultUserScopes
        Nothing -> defaultUserScopes
  Right
    AccessTokenClaims
      { atcSubject = sub,
        atcEmail = email,
        atcJti = jti,
        atcScopes = scopes
      }

-- | Convert a StringOrURI to Text via its JSON representation.
suriToText :: (ToJSON a) => a -> Text
suriToText suri = case toJSON suri of
  String t -> t
  other -> pack $ show other

lookupText :: Text -> Map.Map Text Value -> Either Text Text
lookupText key m =
  case Map.lookup key m of
    Just (String t) -> Right t
    _ -> Left $ "Missing or invalid field: " <> key
