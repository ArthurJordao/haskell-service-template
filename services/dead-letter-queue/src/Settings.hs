module Settings
  ( Settings (..),
    loadSettings,
  )
where

import Crypto.JOSE.JWK (JWK)
import Data.Aeson (eitherDecodeStrict')
import qualified Ports.Consumer as KafkaPort
import qualified Ports.Server as Server
import RIO
import Data.Text (dropEnd, isSuffixOf, splitOn, strip)
import RIO.Text (pack)
import qualified Service.Database as Database
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

data JWTEnvSettings = JWTEnvSettings
  { jwtRawPublicKey :: !String
  }

instance FromEnv JWTEnvSettings where
  fromEnv _ = JWTEnvSettings <$> env "JWT_PUBLIC_KEY"

data CORSEnvSettings = CORSEnvSettings
  { corsRawOrigins :: !String
  }

instance FromEnv CORSEnvSettings where
  fromEnv _ = CORSEnvSettings <$> (env "CORS_ALLOWED_ORIGINS" .!= "http://localhost:5173")

data Settings = Settings
  { server :: !Server.Settings,
    kafka :: !KafkaPort.Settings,
    database :: !Database.Settings,
    jwtPublicKey :: !JWK,
    corsOrigins :: ![Text]
  }

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  serverSettings <- Server.decoder
  kafkaSettings <- KafkaPort.decoder
  dbSettings <- Database.decoder
  jwtEnv <- liftIO (decodeEnv @JWTEnvSettings) >>= either throwString return
  corsEnv <- liftIO (decodeEnv @CORSEnvSettings) >>= either throwString return
  jwk <- case eitherDecodeStrict' (encodeUtf8 (pack (jwtRawPublicKey jwtEnv))) :: Either String JWK of
    Left err -> throwString $ "Invalid JWT_PUBLIC_KEY: " <> err
    Right key -> return key
  let normalizeOrigin t = if "/" `isSuffixOf` t then dropEnd 1 t else t
      origins = filter (/= "") $ map (normalizeOrigin . strip) $ splitOn "," (pack (corsRawOrigins corsEnv))
  return
    Settings
      { server = serverSettings,
        kafka = kafkaSettings,
        database = dbSettings,
        jwtPublicKey = jwk,
        corsOrigins = origins
      }

loadSettings :: LogFunc -> IO Settings
loadSettings logFunc = runRIO logFunc decoder
