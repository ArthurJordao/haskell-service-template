module Settings
  ( Settings (..),
    loadSettings,
  )
where

import qualified Ports.Consumer as KafkaPort
import qualified Ports.Server as Server
import qualified Service.Database as Database
import RIO
import System.Environment (lookupEnv)

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    db :: !Database.Settings,
    templatesDir :: !FilePath,
    notificationsDir :: !FilePath
  }

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  tDir <- liftIO $ fromMaybe "resources/templates" <$> lookupEnv "TEMPLATES_DIR"
  nDir <- liftIO $ fromMaybe "notifications" <$> lookupEnv "NOTIFICATIONS_DIR"
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        db = dbSettings,
        templatesDir = tDir,
        notificationsDir = nDir
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
