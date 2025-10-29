module Service.HttpClient
  ( HttpClient,
    Settings (..),
    HttpError (..),
    HasHttpClient (..),
    decoder,
    initHttpClient,
    callService,
    callServiceGet,
    callServicePost,
    callServicePut,
    callServiceDelete,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, decode, encode)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (Manager, Request, RequestBody (..), Response, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header, RequestHeaders)
import Network.HTTP.Types.Status (statusCode)
import RIO
import RIO.Text (pack, unpack)
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), logErrorC, logInfoC)
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))

-- ============================================================================
-- Types
-- ============================================================================

data Settings = Settings
  { httpClientTimeout :: !Int,
    httpClientMaxRetries :: !Int
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ =
    Settings
      <$> (env "HTTP_CLIENT_TIMEOUT" .!= 30)
      <*> (env "HTTP_CLIENT_MAX_RETRIES" .!= 3)

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode HTTP client settings, using defaults: " <> displayShow err
      return $ Settings 30 3
    Right settings -> return settings

newtype HttpClient = HttpClient
  { httpManager :: Manager
  }

data HttpError
  = HttpParseError Text
  | HttpRequestError Text
  | HttpDecodeError Text
  | HttpStatusError Int BL.ByteString
  deriving (Show, Eq)

-- ============================================================================
-- Typeclass
-- ============================================================================

class HasHttpClient env where
  httpClientL :: Lens' env HttpClient

-- ============================================================================
-- Initialization
-- ============================================================================

initHttpClient :: (HasLogFunc env) => RIO env HttpClient
initHttpClient = do
  logInfo "Initializing HTTP client"
  manager <- liftIO $ newManager tlsManagerSettings
  logInfo "HTTP client initialized successfully"
  return $ HttpClient manager

-- ============================================================================
-- Helper Functions
-- ============================================================================

callService ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a) =>
  Text ->
  Text ->
  RequestHeaders ->
  Maybe BL.ByteString ->
  RIO env (Either HttpError a)
callService method' url extraHeaders maybeBody = do
  client <- view httpClientL
  cid <- view correlationIdL

  logInfoC $ "Calling service: " <> display method' <> " " <> display url

  let cidHeader = ("X-Correlation-Id", TE.encodeUtf8 $ unCorrelationId cid)
      allHeaders = cidHeader : extraHeaders

  result <- makeRequest client method' url allHeaders maybeBody

  case result of
    Left err -> do
      logErrorC $ "Service call failed: " <> displayShow err
      return (Left err)
    Right response -> do
      logInfoC $ "Service call succeeded: " <> display url
      return (Right response)

callServiceGet ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a) =>
  Text ->
  RequestHeaders ->
  RIO env (Either HttpError a)
callServiceGet url headers = callService "GET" url headers Nothing

callServicePost ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a, ToJSON b) =>
  Text ->
  RequestHeaders ->
  b ->
  RIO env (Either HttpError a)
callServicePost url headers body =
  callService "POST" url headers (Just $ encode body)

callServicePut ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a, ToJSON b) =>
  Text ->
  RequestHeaders ->
  b ->
  RIO env (Either HttpError a)
callServicePut url headers body =
  callService "PUT" url headers (Just $ encode body)

callServiceDelete ::
  (HasHttpClient env, HasCorrelationId env, HasLogContext env, HasLogFunc env, FromJSON a) =>
  Text ->
  RequestHeaders ->
  RIO env (Either HttpError a)
callServiceDelete url headers = callService "DELETE" url headers Nothing

-- ============================================================================
-- Internal Functions
-- ============================================================================

makeRequest ::
  (HasLogFunc env, HasLogContext env, FromJSON a) =>
  HttpClient ->
  Text ->
  Text ->
  RequestHeaders ->
  Maybe BL.ByteString ->
  RIO env (Either HttpError a)
makeRequest client method' url headers maybeBody = do
  case parseRequest (unpack url) of
    Nothing -> return $ Left $ HttpParseError $ "Failed to parse URL: " <> url
    Just baseRequest -> do
      let requestWithMethod = baseRequest {method = TE.encodeUtf8 method'}
          requestWithHeaders = requestWithMethod {requestHeaders = headers ++ requestHeaders requestWithMethod}
          finalRequest = case maybeBody of
            Nothing -> requestWithHeaders
            Just body ->
              requestWithHeaders
                { requestBody = RequestBodyLBS body,
                  requestHeaders = ("Content-Type", "application/json") : requestHeaders requestWithHeaders
                }

      result <- tryAny $ liftIO $ httpLbs finalRequest (httpManager client)

      case result of
        Left ex -> return $ Left $ HttpRequestError $ pack $ show ex
        Right response -> processResponse response

processResponse ::
  (FromJSON a) =>
  Response BL.ByteString ->
  RIO env (Either HttpError a)
processResponse response = do
  let status = statusCode $ responseStatus response
      body = responseBody response

  if status >= 200 && status < 300
    then case decode body of
      Nothing -> return $ Left $ HttpDecodeError "Failed to decode response body"
      Just value -> return $ Right value
    else return $ Left $ HttpStatusError status body
