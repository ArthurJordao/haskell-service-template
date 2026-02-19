module Ports.HttpClient
  ( module Service.HttpClient,
    ServiceUrls (..),
    decoderUrls,
    callExternalApi,
  )
where

import Data.Aeson (FromJSON)
import RIO
import RIO.Text (pack)
import Service.CorrelationId (HasCorrelationId, HasLogContext)
import Service.HttpClient
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

-- ============================================================================
-- Configuration
-- ============================================================================

data ServiceUrls = ServiceUrls
  { authServiceUrl :: !Text,
    notificationServiceUrl :: !Text,
    externalApiUrl :: !Text
  }
  deriving (Show, Eq)

instance FromEnv ServiceUrls where
  fromEnv _ =
    ServiceUrls
      <$> (pack <$> (env "AUTH_SERVICE_URL" .!= "http://localhost:8081"))
      <*> (pack <$> (env "NOTIFICATION_SERVICE_URL" .!= "http://localhost:8082"))
      <*> (pack <$> (env "EXTERNAL_API_URL" .!= "https://jsonplaceholder.typicode.com"))

decoderUrls :: (HasLogFunc env) => RIO env ServiceUrls
decoderUrls = do
  result <- liftIO decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode service URLs, using defaults: " <> displayShow err
      return $ ServiceUrls (pack "http://localhost:8081") (pack "http://localhost:8082") (pack "https://jsonplaceholder.typicode.com")
    Right urls -> return urls

-- ============================================================================
-- Example Usage Functions
-- ============================================================================

callExternalApi ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a) =>
  Text ->
  RIO env (Either HttpError a)
callExternalApi endpoint = do
  let url = "https://jsonplaceholder.typicode.com" <> endpoint
  callServiceGet url []
