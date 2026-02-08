module Settings
  ( Settings (..),
    loadSettings,
  )
where

import qualified Ports.Server as Server
import qualified Ports.Kafka as KafkaPort
import RIO
import qualified Service.Database as Database

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    database :: !Database.Settings
  }
  deriving (Show, Eq)

decoder :: (HasLogFunc env) => RIO env Settings
decoder =
  Settings
    <$> Server.decoder
    <*> KafkaPort.decoder
    <*> Database.decoder

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
