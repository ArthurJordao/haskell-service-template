module Settings (
  Settings (..),
  loadSettings,
) where

import qualified Service.Database as Database
import qualified Handlers.Kafka
import qualified Handlers.Server
import RIO


data Settings = Settings
  { http :: !Handlers.Server.Settings,
    kafka :: !Handlers.Kafka.Settings,
    database :: !Database.Settings
  }
  deriving (Show, Eq)


decoder :: (HasLogFunc env) => RIO env Settings
decoder =
  Settings
    <$> Handlers.Server.decoder
    <*> Handlers.Kafka.decoder
    <*> Database.decoder


loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
