module Service.Test.HttpClient
  ( MockHttpClient (..),
    MockHttpState (..),
    MockRequest (..),
    MockResponse (..),
    newMockHttpState,
    mockResponse,
    mockResponseJson,
    getRequests,
    assertRequestMade,
    assertRequestMadeWith,
    mockCallService,
    mockCallServiceGet,
    mockCallServicePost,
    mockCallServicePut,
    mockCallServiceDelete,
  )
where

import Service.HttpClient (HttpError (..))

import Data.Aeson (FromJSON, ToJSON, Value, decode, encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Network.HTTP.Types.Header (RequestHeaders)
import RIO
import qualified RIO.Seq as Seq

-- ============================================================================
-- Types
-- ============================================================================

data MockRequest = MockRequest
  { mrMethod :: Text,
    mrUrl :: Text,
    mrHeaders :: RequestHeaders,
    mrBody :: (Maybe BL.ByteString)
  }
  deriving (Show, Eq)

data MockResponse = MockResponse
  { mrStatusCode :: Int,
    mrResponseBody :: BL.ByteString
  }
  deriving (Show, Eq)

data MockHttpState = MockHttpState
  { mhRequests :: (TVar (Seq MockRequest)),
    mhResponses :: (TVar [(Text, Text, MockResponse)]) -- (method, url, response)
  }

newtype MockHttpClient = MockHttpClient MockHttpState

-- ============================================================================
-- Initialization
-- ============================================================================

newMockHttpState :: IO MockHttpState
newMockHttpState = do
  requests <- newTVarIO Seq.empty
  responses <- newTVarIO []
  return $ MockHttpState requests responses

-- ============================================================================
-- Mock Response Setup
-- ============================================================================

-- | Register a mock response for a specific method and URL
mockResponse :: MockHttpState -> Text -> Text -> Int -> BL.ByteString -> IO ()
mockResponse state method url statusCode body = do
  let response = MockResponse statusCode body
  atomically $ modifyTVar (mhResponses state) ((method, url, response) :)

-- | Register a mock response with JSON body
mockResponseJson :: (ToJSON a) => MockHttpState -> Text -> Text -> Int -> a -> IO ()
mockResponseJson state method url statusCode value = do
  mockResponse state method url statusCode (encode value)

-- ============================================================================
-- Request Verification
-- ============================================================================

-- | Get all recorded requests
getRequests :: MockHttpState -> IO (Seq MockRequest)
getRequests state = readTVarIO (mhRequests state)

-- | Assert that a request was made with the given method and URL
assertRequestMade :: MockHttpState -> Text -> Text -> IO Bool
assertRequestMade state method url = do
  requests <- getRequests state
  return $ any (\r -> mrMethod r == method && mrUrl r == url) (toList requests)

-- | Assert that a request was made with specific body
assertRequestMadeWith :: (FromJSON a, Eq a, Show a) => MockHttpState -> Text -> Text -> a -> IO Bool
assertRequestMadeWith state method url expectedBody = do
  requests <- getRequests state
  let matchingRequests = filter (\r -> mrMethod r == method && mrUrl r == url) (toList requests)
  case matchingRequests of
    [] -> return False
    (req : _) -> case mrBody req of
      Nothing -> return False
      Just body -> case decode body of
        Nothing -> return False
        Just actualBody -> return $ actualBody == expectedBody

-- ============================================================================
-- Mock HTTP Execution
-- ============================================================================

-- | Record a request and return a mock response
mockExecuteRequest ::
  MockHttpState ->
  Text ->
  Text ->
  RequestHeaders ->
  Maybe BL.ByteString ->
  IO (Maybe MockResponse)
mockExecuteRequest state method url headers body = do
  -- Record the request
  let request = MockRequest method url headers body
  atomically $ modifyTVar (mhRequests state) (Seq.|> request)

  -- Find matching response
  responses <- readTVarIO (mhResponses state)
  return $ findResponse responses method url
  where
    findResponse :: [(Text, Text, MockResponse)] -> Text -> Text -> Maybe MockResponse
    findResponse [] _ _ = Nothing
    findResponse ((m, u, r) : rest) method' url'
      | m == method' && u == url' = Just r
      | otherwise = findResponse rest method' url'

-- ============================================================================
-- Mock Call Functions (for use in tests)
-- ============================================================================

mockCallService ::
  (FromJSON a, MonadIO m) =>
  MockHttpState ->
  Text ->
  Text ->
  RequestHeaders ->
  Maybe BL.ByteString ->
  m (Either HttpError a)
mockCallService state method url headers body = liftIO $ do
  maybeResponse <- mockExecuteRequest state method url headers body
  case maybeResponse of
    Nothing -> return $ Left $ HttpRequestError $ "No mock response configured for " <> method <> " " <> url
    Just (MockResponse statusCode responseBody) ->
      if statusCode >= 200 && statusCode < 300
        then case decode responseBody of
          Nothing -> return $ Left $ HttpDecodeError "Failed to decode mock response body"
          Just value -> return $ Right value
        else return $ Left $ HttpStatusError statusCode responseBody

mockCallServiceGet ::
  (FromJSON a, MonadIO m) =>
  MockHttpState ->
  Text ->
  RequestHeaders ->
  m (Either HttpError a)
mockCallServiceGet state url headers = mockCallService state "GET" url headers Nothing

mockCallServicePost ::
  (FromJSON a, ToJSON b, MonadIO m) =>
  MockHttpState ->
  Text ->
  RequestHeaders ->
  b ->
  m (Either HttpError a)
mockCallServicePost state url headers body =
  mockCallService state "POST" url headers (Just $ encode body)

mockCallServicePut ::
  (FromJSON a, ToJSON b, MonadIO m) =>
  MockHttpState ->
  Text ->
  RequestHeaders ->
  b ->
  m (Either HttpError a)
mockCallServicePut state url headers body =
  mockCallService state "PUT" url headers (Just $ encode body)

mockCallServiceDelete ::
  (FromJSON a, MonadIO m) =>
  MockHttpState ->
  Text ->
  RequestHeaders ->
  m (Either HttpError a)
mockCallServiceDelete state url headers = mockCallService state "DELETE" url headers Nothing
