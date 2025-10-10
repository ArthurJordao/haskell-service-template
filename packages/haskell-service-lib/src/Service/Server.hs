module Service.Server
  ( Settings (..),
    decoder,
  )
where

import RIO
import RIO.Text (pack)
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

data Settings = Settings
  { httpPort :: !Int,
    httpEnvironment :: !Text
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ =
    Settings
      <$> (env "PORT" .!= 8080)
      <*> (pack <$> (env "ENVIRONMENT" .!= "development"))

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO $ decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode HTTP settings, using defaults: " <> displayShow err
      return $ Settings 8080 "development"
    Right settings -> return settings
