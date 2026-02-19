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
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

-- | Raw JWT environment variables (decoded via envy).
data JWTEnvSettings = JWTEnvSettings
  { jwtRawPrivateKey :: !String,
    jwtRawAccessExpiry :: !Int,
    jwtRawRefreshExpiry :: !Int
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ =
    JWTEnvSettings
      <$> env "JWT_PRIVATE_KEY"
      <*> (env "JWT_ACCESS_TOKEN_EXPIRY_SECONDS" .!= 900)
      <*> (env "JWT_REFRESH_TOKEN_EXPIRY_DAYS" .!= 7)

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    database :: !Database.Settings,
    jwt :: !JWTSettings
  }

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  jwtEnv <- liftIO (decodeEnv @JWTEnvSettings) >>= either throwString return
  jwk <- case eitherDecodeStrict' (encodeUtf8 (pack (jwtRawPrivateKey jwtEnv))) :: Either String JWK of
    Left err -> throwString $ "Invalid JWT_PRIVATE_KEY: " <> err
    Right key -> return key
  let jwtSettings =
        JWTSettings
          { jwtPrivateKey = jwk,
            jwtAccessTokenExpirySeconds = jwtRawAccessExpiry jwtEnv,
            jwtRefreshTokenExpiryDays = jwtRawRefreshExpiry jwtEnv
          }
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        database = dbSettings,
        jwt = jwtSettings
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
