module Settings
  ( Settings (..),
    loadSettings,
  )
where

import qualified Ports.Server as Server
import qualified Ports.Consumer as KafkaPort
import RIO
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env)

data JWTEnvSettings = JWTEnvSettings
  { jwtRawSecret :: !String
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ = JWTEnvSettings <$> env "JWT_SECRET"

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    database :: !Database.Settings,
    jwtSecret :: !Text
  }
  deriving (Show, Eq)

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  jwtEnv <- liftIO (decodeEnv @JWTEnvSettings) >>= either throwString return
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        database = dbSettings,
        jwtSecret = pack (jwtRawSecret jwtEnv)
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
