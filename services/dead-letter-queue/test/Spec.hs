{-# LANGUAGE FlexibleContexts #-}

import Ports.Server (API, DeadLetterResponse (..), ReplayResult (..), DLQStats (..))
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode, Value)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime)
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool, insert)
import qualified Ports.Server as Server
import qualified Ports.Kafka as KafkaPort
import Kafka.Consumer (TopicName (..))
import Models.DeadLetter (DeadLetter (..), migrateAll)
import Network.HTTP.Client (RequestBody (..), defaultManagerSettings, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Types.Status (status200, status404)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import RIO
import RIO.Text (pack)
import qualified RIO.Seq as Seq
import Control.Monad.Trans.Except (ExceptT (..))
import Servant (ServerError, hoistServer, serve)
import qualified Servant
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), defaultCorrelationId, logInfoC, unCorrelationId)
import Service.Test.Kafka (MockConsumer (..), MockKafkaState (..), MockProducer (..), QueuedMessage (..), consumedMessages, mockProduceMessage, newMockKafkaState, processAllMessages)
import Settings (Settings (..))
import Test.Hspec

-- Test application with mock Kafka
data TestApp = TestApp
  { testAppLogFunc :: !LogFunc,
    testAppLogContext :: !(Map Text Text),
    testAppSettings :: !Settings,
    testAppCorrelationId :: !CorrelationId,
    testAppDb :: !ConnectionPool,
    testAppMockKafka :: !MockKafkaState
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

withTestApp :: (Int -> TestApp -> IO ()) -> IO ()
withTestApp action = do
  let testSettings =
        Settings
          { server = Server.Settings {Server.httpPort = 8090, Server.httpEnvironment = "test"},
            kafka = KafkaPort.Settings {KafkaPort.kafkaBroker = "localhost:9092", KafkaPort.kafkaGroupId = "dlq-test-group", KafkaPort.kafkaDeadLetterTopic = "DEADLETTER", KafkaPort.kafkaMaxRetries = 3},
            database = Database.Settings {Database.dbType = Database.SQLite, Database.dbConnectionString = ":memory:", Database.dbPoolSize = 1, Database.dbAutoMigrate = True}
          }
  logOptions <- logOptionsHandle stderr True
  withLogFunc logOptions $ \logFunc -> runRIO logFunc $ do
    mockKafkaState <- liftIO newMockKafkaState
    pool <- liftIO $ Database.createConnectionPool testSettings.database
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

    let testApp =
          TestApp
            { testAppLogFunc = logFunc,
              testAppLogContext = Map.empty,
              testAppSettings = testSettings,
              testAppCorrelationId = defaultCorrelationId,
              testAppDb = pool,
              testAppMockKafka = mockKafkaState
            }

    liftIO $ testWithApplication (pure $ testAppToWai testApp) $ \port' -> action port' testApp

testAppToWai :: TestApp -> Application
testAppToWai env = serve (Proxy @Server.API) (hoistServer (Proxy @Server.API) (nt env) Server.server)
  where
    nt :: TestApp -> RIO TestApp a -> Servant.Handler a
    nt e action = Servant.Handler $ ExceptT $ try $ runRIO e action

-- Helper to seed a dead letter message directly into the database
seedDeadLetter :: TestApp -> IO ()
seedDeadLetter testApp = do
  now <- getCurrentTime
  let dl = DeadLetter
        { deadLetterOriginalTopic = "test-topic",
          deadLetterOriginalMessage = "{\"key\":\"value\"}",
          deadLetterOriginalHeaders = "[]",
          deadLetterErrorType = "HANDLER_ERROR",
          deadLetterErrorDetails = "Test error",
          deadLetterCorrelationId = "test-cid-123",
          deadLetterCreatedAt = now,
          deadLetterRetryCount = 1,
          deadLetterStatus = "pending",
          deadLetterReplayedAt = Nothing,
          deadLetterReplayedBy = Nothing,
          deadLetterReplayResult = Nothing
        }
  runRIO testApp $ do
    pool <- view dbL
    void $ runSqlPoolWithCid (insert dl) pool
  where
    runSqlPoolWithCid = Database.runSqlPoolWithCid

spec :: Spec
spec = describe "Dead Letter Queue Service" $ do
  it "responds with 200 on status" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/status")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200
      responseBody response `shouldBe` "\"OK\""

  it "returns empty list when no dead letters exist" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/dlq")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200
      responseBody response `shouldBe` "[]"

  it "returns 404 for non-existent dead letter" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/dlq/999")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status404

  it "lists dead letter messages after seeding" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/dlq")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeMessages = decode @[DeadLetterResponse] (responseBody response)
      maybeMessages `shouldSatisfy` isJust

      case maybeMessages of
        Just [msg] -> do
          dlrOriginalTopic msg `shouldBe` "test-topic"
          dlrErrorType msg `shouldBe` "HANDLER_ERROR"
          dlrStatus msg `shouldBe` "pending"
        Just msgs -> expectationFailure $ "Expected 1 message, got " <> show (length msgs)
        Nothing -> expectationFailure "Failed to decode response"

  it "gets dead letter by ID" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/dlq/1")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeDl = decode @DeadLetterResponse (responseBody response)
      maybeDl `shouldSatisfy` isJust

      case maybeDl of
        Just dl -> do
          dlrId dl `shouldBe` 1
          dlrCorrelationId dl `shouldBe` "test-cid-123"
        Nothing -> expectationFailure "Failed to decode response"

  it "replays a dead letter message and produces to Kafka" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      initialRequest <- parseRequest ("http://localhost:" <> show port' <> "/dlq/1/replay")
      let request = initialRequest {method = "POST"}
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeResult = decode @ReplayResult (responseBody response)
      maybeResult `shouldSatisfy` isJust

      case maybeResult of
        Just result -> do
          replayId result `shouldBe` 1
          replaySuccess result `shouldBe` True
          replayError result `shouldBe` Nothing
        Nothing -> expectationFailure "Failed to decode replay result"

      -- Verify Kafka message was produced
      let mockState = testAppMockKafka testApp
      messages <- atomically $ readTVar (messageQueue mockState)
      Seq.length messages `shouldBe` 1

      case Seq.viewl messages of
        msg Seq.:< _ -> qmTopic msg `shouldBe` TopicName "test-topic"
        Seq.EmptyL -> expectationFailure "No messages in Kafka queue"

  it "discards a dead letter message" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      initialRequest <- parseRequest ("http://localhost:" <> show port' <> "/dlq/1/discard")
      let request = initialRequest {method = "POST"}
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      -- Verify status changed to discarded
      getRequest <- parseRequest ("http://localhost:" <> show port' <> "/dlq/1")
      getResponse <- httpLbs getRequest manager
      let maybeDl = decode @DeadLetterResponse (responseBody getResponse)
      case maybeDl of
        Just dl -> dlrStatus dl `shouldBe` "discarded"
        Nothing -> expectationFailure "Failed to decode response"

  it "returns stats" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- parseRequest ("http://localhost:" <> show port' <> "/dlq/stats")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeStats = decode @DLQStats (responseBody response)
      maybeStats `shouldSatisfy` isJust

      case maybeStats of
        Just stats -> do
          totalMessages stats `shouldBe` 1
          pendingMessages stats `shouldBe` 1
          replayedMessages stats `shouldBe` 0
          discardedMessages stats `shouldBe` 0
        Nothing -> expectationFailure "Failed to decode stats"

main :: IO ()
main = hspec $ do
  spec
