import API (API, AccountCreatedEvent (..), CreateAccountRequest (..))
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode)
import qualified Data.Map.Strict as Map
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import qualified Handlers.Kafka
import qualified Handlers.Server
import Kafka.Consumer (TopicName (..))
import Models.Account (Account (..), migrateAll)
import Network.HTTP.Client (RequestBody (..), defaultManagerSettings, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Types.Status (status200)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import RIO
import qualified RIO.Seq as Seq
import Servant (hoistServer, serve)
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import Service.Test.Kafka (MockConsumer (..), MockKafkaState (..), MockProducer (..), QueuedMessage (..), consumedMessages, mockProduceMessage, newMockKafkaState, processAllMessages)
import Settings (Settings (..))
import Test.Hspec

-- Test application with mock Kafka
data TestApp = TestApp
  { testAppLogFunc :: !LogFunc,
    testAppLogContext :: !(Map Text Text),
    testAppSettings :: !Settings,
    testAppDb :: !ConnectionPool,
    testAppMockKafka :: !MockKafkaState
  }

instance HasLogFunc TestApp where
  logFuncL = lens testAppLogFunc (\x y -> x {testAppLogFunc = y})

instance HasLogContext TestApp where
  logContextL = lens testAppLogContext (\x y -> x {testAppLogContext = y})

instance Handlers.Server.HasConfig TestApp Settings where
  settingsL = lens testAppSettings (\x y -> x {testAppSettings = y})
  http = Settings.http

instance HasDB TestApp where
  dbL = lens testAppDb (\x y -> x {testAppDb = y})

instance {-# OVERLAPPING #-} HasKafkaProducer TestApp where
  produceKafkaMessage topic key value = do
    state <- view (to testAppMockKafka)
    let producer = MockProducer state
    mockProduceMessage producer topic key value

withTestApp :: (Int -> TestApp -> IO ()) -> IO ()
withTestApp action = do
  let testSettings =
        Settings
          { http = Handlers.Server.Settings {Handlers.Server.httpPort = 8080, Handlers.Server.httpEnvironment = "test"},
            kafka = Handlers.Kafka.Settings {Handlers.Kafka.kafkaBroker = "localhost:9092", Handlers.Kafka.kafkaGroupId = "test-group"},
            database = Database.Settings {Database.dbType = Database.SQLite, Database.dbConnectionString = ":memory:", Database.dbPoolSize = 1, Database.dbAutoMigrate = True}
          }
  logOptions <- logOptionsHandle stderr True
  withLogFunc logOptions $ \logFunc -> do
    -- Setup mock Kafka and real database
    mockKafkaState <- newMockKafkaState
    pool <- liftIO $ Database.createConnectionPool testSettings.database
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

    let testApp =
          TestApp
            { testAppLogFunc = logFunc,
              testAppLogContext = Map.empty,
              testAppSettings = testSettings,
              testAppDb = pool,
              testAppMockKafka = mockKafkaState
            }

    testWithApplication (pure $ testAppToWai testApp) $ \port' -> action port' testApp

testAppToWai :: TestApp -> Application
testAppToWai env = serve (Proxy @API) (hoistServer (Proxy @API) (runRIO env) Handlers.Server.server)

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
          consumerCfg = Handlers.Kafka.consumerConfig (Settings.kafka $ testAppSettings testApp)
      runRIO testApp $ processAllMessages mockConsumer consumerCfg

      -- Verify messages were consumed
      consumed <- atomically $ readTVar (consumedMessages mockState)
      Seq.length consumed `shouldBe` 1

      -- Verify the message queue is now empty (all messages processed)
      remainingMessages <- atomically $ readTVar (messageQueue mockState)
      Seq.length remainingMessages `shouldBe` 0

main :: IO ()
main = hspec $ do
  spec
