{-# LANGUAGE FlexibleContexts #-}

import Ports.Server (API, AccountCreatedEvent (..), CreateAccountRequest (..))
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode)
import qualified Data.Map.Strict as Map
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import qualified Ports.Server as Server
import qualified Ports.Kafka as KafkaPort
import Kafka.Consumer (TopicName (..))
import Models.Account (Account (..), migrateAll)
import Network.HTTP.Client (RequestBody (..), defaultManagerSettings, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Types.Status (status200)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import RIO
import RIO.Text (pack)
import qualified RIO.Text as T
import qualified RIO.Seq as Seq
import Servant (err500, errBody, hoistServer, serve)
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import Service.HttpClient (HttpClient, HasHttpClient (..), HttpError (..))
import qualified Service.HttpClient as HttpClient
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), defaultCorrelationId, logInfoC, unCorrelationId)
import qualified Data.Text.Encoding as TE
import Service.Test.Kafka (MockConsumer (..), MockKafkaState (..), MockProducer (..), QueuedMessage (..), consumedMessages, mockProduceMessage, newMockKafkaState, processAllMessages)
import Service.Test.HttpClient (MockHttpState, MockRequest (..), assertRequestMade, mockResponse, newMockHttpState, getRequests)
import qualified Service.Test.HttpClient as MockHttp
import Settings (Settings (..))
import Test.Hspec

-- Test application with mock Kafka and mock HTTP
data TestApp = TestApp
  { testAppLogFunc :: !LogFunc,
    testAppLogContext :: !(Map Text Text),
    testAppSettings :: !Settings,
    testAppCorrelationId :: !CorrelationId,
    testAppDb :: !ConnectionPool,
    testAppMockKafka :: !MockKafkaState,
    testAppHttpClient :: !HttpClient,
    testAppMockHttp :: !MockHttpState
  }

instance HasLogFunc TestApp where
  logFuncL = lens testAppLogFunc (\x y -> x {testAppLogFunc = y})

instance HasLogContext TestApp where
  logContextL = lens testAppLogContext (\x y -> x {testAppLogContext = y})

instance HasCorrelationId TestApp where
  correlationIdL = lens testAppCorrelationId (\x y -> x {testAppCorrelationId = y})

instance Server.HasConfig TestApp Settings where
  settingsL = lens testAppSettings (\x y -> x {testAppSettings = y})
  httpSettings = Settings.server

instance HasDB TestApp where
  dbL = lens testAppDb (\x y -> x {testAppDb = y})

instance {-# OVERLAPPING #-} HasKafkaProducer TestApp where
  produceKafkaMessage topic key value = do
    state <- view (to testAppMockKafka)
    let producer = MockProducer state
    mockProduceMessage producer topic key value

-- Use a custom HTTP client implementation that intercepts calls
-- We can't use overlapping instances for HasHttpClient easily, so we'll
-- need to modify the handler to allow injection of mock HTTP calls
instance HasHttpClient TestApp where
  httpClientL = lens testAppHttpClient (\x y -> x {testAppHttpClient = y})

-- Helper to get mock HTTP state
class HasMockHttp env where
  mockHttpL :: Lens' env MockHttpState

instance HasMockHttp TestApp where
  mockHttpL = lens testAppMockHttp (\x y -> x {testAppMockHttp = y})

-- Test-specific server routes that use mock HTTP
testExternalPostHandler :: (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasMockHttp env) => Int -> RIO env Server.ExternalPost
testExternalPostHandler postId = do
  logInfoC $ "Fetching external post with ID: " <> displayShow postId
  mockState <- view mockHttpL
  cid <- view correlationIdL
  let url = "https://jsonplaceholder.typicode.com/posts/" <> pack (show postId)
      cidHeader = ("X-Correlation-Id", TE.encodeUtf8 $ unCorrelationId cid)
  result <- MockHttp.mockCallServiceGet mockState url [cidHeader]
  case result of
    Left err -> do
      logInfoC $ "Failed to fetch external post: " <> displayShow err
      throwM err500 {errBody = "Failed to fetch external post"}
    Right post -> do
      logInfoC $ "Successfully fetched external post: " <> displayShow (Server.title post)
      return post

-- Test server with mock HTTP handler - we reuse most of the real server but override the external post handler
testServer :: (HasLogFunc env, HasLogContext env, HasCorrelationId env, Server.HasConfig env Settings, HasDB env, HasKafkaProducer env, HasHttpClient env, HasMockHttp env) => Server.Routes (AsServerT (RIO env))
testServer =
  let realServer = Server.server
   in realServer {Server.getExternalPost = testExternalPostHandler}

withTestApp :: (Int -> TestApp -> IO ()) -> IO ()
withTestApp action = do
  let testSettings =
        Settings
          { server = Server.Settings {Server.httpPort = 8080, Server.httpEnvironment = "test"},
            kafka = KafkaPort.Settings {KafkaPort.kafkaBroker = "localhost:9092", KafkaPort.kafkaGroupId = "test-group", KafkaPort.kafkaDeadLetterTopic = "DEADLETTER", KafkaPort.kafkaMaxRetries = 3},
            database = Database.Settings {Database.dbType = Database.SQLite, Database.dbConnectionString = ":memory:", Database.dbPoolSize = 1, Database.dbAutoMigrate = True}
          }
  logOptions <- logOptionsHandle stderr True
  withLogFunc logOptions $ \logFunc -> runRIO logFunc $ do
    -- Setup mock Kafka, real database, HTTP client, and mock HTTP state
    mockKafkaState <- liftIO newMockKafkaState
    mockHttpState <- liftIO newMockHttpState
    pool <- liftIO $ Database.createConnectionPool testSettings.database
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
    httpClient <- HttpClient.initHttpClient

    let testApp =
          TestApp
            { testAppLogFunc = logFunc,
              testAppLogContext = Map.empty,
              testAppSettings = testSettings,
              testAppCorrelationId = defaultCorrelationId,
              testAppDb = pool,
              testAppMockKafka = mockKafkaState,
              testAppHttpClient = httpClient,
              testAppMockHttp = mockHttpState
            }

    liftIO $ testWithApplication (pure $ testAppToWai testApp) $ \port' -> action port' testApp

testAppToWai :: TestApp -> Application
testAppToWai env = serve (Proxy @Server.API) (hoistServer (Proxy @Server.API) (runRIO env) testServer)

spec :: Spec
spec = describe "Server" $ do
  it "respond with 200 on status" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/status")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200
      responseBody response `shouldBe` "\"OK\""

  it "create account and produce Kafka message" $ do
    withTestApp $ \port' testApp -> do
      manager <- newManager defaultManagerSettings

      -- Create account request
      let createReq =
            CreateAccountRequest
              { createAccountName = "John Doe",
                createAccountEmail = "john@example.com"
              }

      initialRequest <- parseRequest ("http://localhost:" <> show port' <> "/accounts")
      let request =
            initialRequest
              { method = "POST",
                requestBody = RequestBodyLBS (encode createReq),
                requestHeaders = [("Content-Type", "application/json")]
              }

      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      -- Verify the response contains the created account
      let maybeAccount = decode @Account (responseBody response)
      maybeAccount `shouldSatisfy` isJust

      case maybeAccount of
        Just account -> do
          accountName account `shouldBe` "John Doe"
          accountEmail account `shouldBe` "john@example.com"
        Nothing -> expectationFailure "Failed to decode account response"

      -- Verify Kafka message was produced
      let mockState = testAppMockKafka testApp
      messages <- atomically $ readTVar (messageQueue mockState)
      Seq.length messages `shouldBe` 1

      case Seq.viewl messages of
        msg Seq.:< _ -> do
          qmTopic msg `shouldBe` TopicName "account-created"

          -- Verify message content (qmValue is now a Value directly)
          let decoded = decode @AccountCreatedEvent (encode (qmValue msg))
          decoded `shouldSatisfy` isJust

          case decoded of
            Just event -> do
              eventAccountId event `shouldBe` 1
              eventAccountName event `shouldBe` "John Doe"
              eventAccountEmail event `shouldBe` "john@example.com"
            Nothing -> expectationFailure "Failed to decode AccountCreatedEvent"
        Seq.EmptyL -> expectationFailure "No messages in queue"

      -- Process messages through the consumer
      let mockConsumer = MockConsumer mockState
          consumerCfg = KafkaPort.consumerConfig (Settings.kafka $ testAppSettings testApp)
      runRIO testApp $ processAllMessages mockConsumer consumerCfg

      -- Verify messages were consumed
      consumed <- atomically $ readTVar (consumedMessages mockState)
      Seq.length consumed `shouldBe` 1

      -- Verify the message queue is now empty (all messages processed)
      remainingMessages <- atomically $ readTVar (messageQueue mockState)
      Seq.length remainingMessages `shouldBe` 0

  it "fetch external post via HTTP client (mocked)" $ do
    withTestApp $ \port' testApp -> do
      let mockHttpState = testAppMockHttp testApp

      -- Setup mock response for the external API call
      let mockPost =
            Server.ExternalPost
              { Server.userId = 1,
                Server.id = 1,
                Server.title = "Mock Post Title",
                Server.body = "Mock post body content"
              }
      mockResponse mockHttpState "GET" "https://jsonplaceholder.typicode.com/posts/1" 200 (encode mockPost)

      manager <- newManager defaultManagerSettings

      -- Call the endpoint that will trigger the HTTP client (but it's mocked)
      request <- parseRequest ("http://localhost:" <> show port' <> "/external/posts/1")
      response <- httpLbs request manager

      -- Verify we got a 200 response
      responseStatus response `shouldBe` status200

      -- Verify the response body contains the mocked data
      let maybePost = decode @Server.ExternalPost (responseBody response)
      maybePost `shouldSatisfy` isJust

      case maybePost of
        Just post -> do
          Server.id post `shouldBe` 1
          Server.userId post `shouldBe` 1
          Server.title post `shouldBe` "Mock Post Title"
          Server.body post `shouldBe` "Mock post body content"
        Nothing -> expectationFailure "Failed to decode ExternalPost response"

      -- Get all requests and verify details
      requests <- getRequests mockHttpState

      -- Debug: print requests if test fails
      when (Seq.length requests == 0) $
        expectationFailure "No HTTP requests were recorded in mock"

      Seq.length requests `shouldBe` 1

      -- Verify the actual request details
      case Seq.viewl requests of
        req Seq.:< _ -> do
          mrMethod req `shouldBe` "GET"
          mrUrl req `shouldBe` "https://jsonplaceholder.typicode.com/posts/1"

      -- Verify the HTTP request was made as expected using assertion helper
      wasMade <- assertRequestMade mockHttpState "GET" "https://jsonplaceholder.typicode.com/posts/1"
      wasMade `shouldBe` True

      case Seq.viewl requests of
        req Seq.:< _ -> do
          -- Verify correlation ID was included in headers
          let hasCorrelationId = any (\(name, _) -> name == "X-Correlation-Id") (mrHeaders req)
          hasCorrelationId `shouldBe` True
        Seq.EmptyL -> expectationFailure "No requests were recorded"

main :: IO ()
main = hspec $ do
  spec
