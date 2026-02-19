module Settings
  ( Settings (..),
    loadSettings,
  )
where

import Auth.JWT (JWTSettings (..), makeJWTKey)
import qualified Ports.Consumer as KafkaPort
import qualified Ports.Server as Server
import RIO
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

-- | Raw JWT environment variables (decoded via envy).
data JWTEnvSettings = JWTEnvSettings
  { jwtRawSecret :: !String,
    jwtRawAccessExpiry :: !Int,
    jwtRawRefreshExpiry :: !Int
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ =
    JWTEnvSettings
      <$> env "JWT_SECRET"
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
  let jwtSettings =
        JWTSettings
          { jwtKey = makeJWTKey (encodeUtf8 (pack (jwtRawSecret jwtEnv))),
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
