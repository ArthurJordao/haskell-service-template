module Settings
  ( Settings (..),
    loadSettings,
  )
where

import qualified Ports.Server as Server
import qualified Ports.Consumer as KafkaPort
import Crypto.JOSE.JWK (JWK)
import Data.Aeson (eitherDecodeStrict')
import RIO
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env)

data JWTEnvSettings = JWTEnvSettings
  { jwtRawPublicKey :: String
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ = JWTEnvSettings <$> env "JWT_PUBLIC_KEY"

data Settings = Settings
  { server :: Server.Settings,
    kafka :: KafkaPort.Settings,
    database :: Database.Settings,
    jwtPublicKey :: JWK
  }

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  jwtEnv <- liftIO (decodeEnv @JWTEnvSettings) >>= either throwString return
  jwk <- case eitherDecodeStrict' (encodeUtf8 (pack (jwtRawPublicKey jwtEnv))) :: Either String JWK of
    Left err -> throwString $ "Invalid JWT_PUBLIC_KEY: " <> err
    Right key -> return key
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        database = dbSettings,
        jwtPublicKey = jwk
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
