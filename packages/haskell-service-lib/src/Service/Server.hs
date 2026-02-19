module Service.Server
  ( Settings (..),
    decoder,
    jsonErrorFormatters,
  )
where

import Data.Aeson (encode, object, (.=))
import RIO
import RIO.Text (pack)
import Servant.Server (ErrorFormatters (..), ServerError (..), defaultErrorFormatters, err400, err404)
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

jsonErrorFormatters :: ErrorFormatters
jsonErrorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = jsonErrF,
      urlParseErrorFormatter = jsonErrF,
      headerParseErrorFormatter = jsonErrF,
      notFoundErrorFormatter = \_ ->
        err404
          { errBody = encode (object ["error" .= ("Not found" :: String)]),
            errHeaders = [("Content-Type", "application/json;charset=utf-8")]
          }
    }
  where
    jsonErrF _ _ msg =
      err400
        { errBody = encode (object ["error" .= msg]),
          errHeaders = [("Content-Type", "application/json;charset=utf-8")]
        }
