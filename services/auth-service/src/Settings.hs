module Settings
  ( Settings (..),
    loadSettings,
  )
where

import Auth.JWT (JWTSettings (..))
import Crypto.JOSE.JWK (JWK)
import Data.Aeson (eitherDecodeStrict')
import qualified Ports.Consumer as KafkaPort
import qualified Ports.Server as Server
import RIO
import Data.Text (dropEnd, isSuffixOf, splitOn, strip)
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

-- | Raw JWT environment variables (decoded via envy).
data JWTEnvSettings = JWTEnvSettings
  { jwtRawPrivateKey :: !String,
    jwtRawAccessExpiry :: !Int,
    jwtRawRefreshExpiry :: !Int,
    jwtRawAdminEmails :: !String
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ =
    JWTEnvSettings
      <$> env "JWT_PRIVATE_KEY"
      <*> (env "JWT_ACCESS_TOKEN_EXPIRY_SECONDS" .!= 900)
      <*> (env "JWT_REFRESH_TOKEN_EXPIRY_DAYS" .!= 7)
      <*> (env "ADMIN_EMAILS" .!= "")

data CORSEnvSettings = CORSEnvSettings
  { corsRawOrigins :: !String
  }

instance FromEnv CORSEnvSettings where
  fromEnv _ = CORSEnvSettings <$> (env "CORS_ALLOWED_ORIGINS" .!= "http://localhost:5173")

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    database :: !Database.Settings,
    jwt :: !JWTSettings,
    corsOrigins :: ![Text]
  }

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  jwtEnv <- liftIO (decodeEnv @JWTEnvSettings) >>= either throwString return
  corsEnv <- liftIO (decodeEnv @CORSEnvSettings) >>= either throwString return
  jwk <- case eitherDecodeStrict' (encodeUtf8 (pack (jwtRawPrivateKey jwtEnv))) :: Either String JWK of
    Left err -> throwString $ "Invalid JWT_PRIVATE_KEY: " <> err
    Right key -> return key
  let normalizeOrigin t = if "/" `isSuffixOf` t then dropEnd 1 t else t
      adminEmails = filter (/= "") $ map strip $ splitOn "," (pack (jwtRawAdminEmails jwtEnv))
      origins = filter (/= "") $ map (normalizeOrigin . strip) $ splitOn "," (pack (corsRawOrigins corsEnv))
      jwtSettings =
        JWTSettings
          { jwtPrivateKey = jwk,
            jwtAccessTokenExpirySeconds = jwtRawAccessExpiry jwtEnv,
            jwtRefreshTokenExpiryDays = jwtRawRefreshExpiry jwtEnv,
            jwtAdminEmails = adminEmails
          }
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        database = dbSettings,
        jwt = jwtSettings,
        corsOrigins = origins
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
