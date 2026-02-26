{-# LANGUAGE FlexibleContexts #-}

import Crypto.JOSE.JWA.JWK (OKPCrv (..), KeyMaterialGenParam (..))
import Crypto.JOSE.JWK (genJWK)
import Ports.Server (API, DeadLetterResponse (..), ReplayResult (..), DLQStats (..))
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode, Value)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime)
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool, insert)
import qualified Ports.Server as Server
import qualified Ports.Consumer as KafkaPort
import Kafka.Consumer (TopicName (..))
import DB.DeadLetter (DeadLetter (..), migrateAll)
import Network.HTTP.Client (Request, RequestBody (..), defaultManagerSettings, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Types.Status (status200, status404)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import RIO
import RIO.Text (pack)
import qualified RIO.Seq as Seq
import Control.Monad.Trans.Except (ExceptT (..))
import qualified Data.Text as T
import Servant (ServerError)
import qualified Servant
import Servant.Server (Context (..), hoistServerWithContext, serveWithContext)
import Service.Auth (AccessTokenClaims (..), JWTAuthConfig (..))
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
  { testAppLogFunc :: LogFunc,
    testAppLogContext :: (Map Text Text),
    testAppSettings :: Settings,
    testAppCorrelationId :: CorrelationId,
    testAppDb :: ConnectionPool,
    testAppMockKafka :: MockKafkaState
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
  jwk <- liftIO $ genJWK (OKPGenParam Ed25519)
  let testSettings =
        Settings
          { server = Server.Settings {Server.httpPort = 8090, Server.httpEnvironment = "test"},
            kafka = KafkaPort.Settings {KafkaPort.kafkaBroker = "localhost:9092", KafkaPort.kafkaGroupId = "dlq-test-group", KafkaPort.kafkaDeadLetterTopic = "DEADLETTER", KafkaPort.kafkaMaxRetries = 3},
            database = Database.Settings {Database.dbType = Database.SQLite, Database.dbConnectionString = ":memory:", Database.dbPoolSize = 1, Database.dbAutoMigrate = True},
            jwtPublicKey = jwk,
            corsOrigins = []
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

-- | A mock JWTAuthConfig that accepts "token-admin" as an admin bearer token.
mockJwtConfig :: JWTAuthConfig
mockJwtConfig =
  JWTAuthConfig
    { jwtAuthValidate = \token ->
        if "token-admin" `T.isPrefixOf` token
          then return $
            Right
              AccessTokenClaims
                { atcSubject = "user-test",
                  atcEmail = Just "test@example.com",
                  atcJti = "jti-test",
                  atcScopes = ["admin"]
                }
          else return (Left "invalid token"),
      jwtAuthSubjectPrefix = "user-"
    }

type TestAppContext = '[JWTAuthConfig]

testAppToWai :: TestApp -> Application
testAppToWai env =
  serveWithContext (Proxy @Server.API) (mockJwtConfig :. EmptyContext) $
    hoistServerWithContext
      (Proxy @Server.API)
      (Proxy @TestAppContext)
      toHandler
      Server.server
  where
    toHandler :: forall a. RIO TestApp a -> Servant.Handler a
    toHandler action =
      Servant.Handler $ ExceptT $
        (Right <$> runRIO env action)
          `catch` (\(e :: ServerError) -> return (Left e))

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

-- | Add an admin bearer token to an outgoing request.
addAdminAuth :: Request -> Request
addAdminAuth req = req { requestHeaders = ("Authorization", "Bearer token-admin") : requestHeaders req }

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
      request <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200
      responseBody response `shouldBe` "[]"

  it "returns 404 for non-existent dead letter" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq/999")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status404

  it "lists dead letter messages after seeding" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeMessages = decode @[DeadLetterResponse] (responseBody response)
      maybeMessages `shouldSatisfy` isJust

      case maybeMessages of
        Just [msg] -> do
          originalTopic msg `shouldBe` "test-topic"
          errorType msg `shouldBe` "HANDLER_ERROR"
          status msg `shouldBe` "pending"
        Just msgs -> expectationFailure $ "Expected 1 message, got " <> show (length msgs)
        Nothing -> expectationFailure "Failed to decode response"

  it "gets dead letter by ID" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq/1")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeDl = decode @DeadLetterResponse (responseBody response)
      maybeDl `shouldSatisfy` isJust

      case maybeDl of
        Just dl -> do
          dl.id `shouldBe` 1
          correlationId dl `shouldBe` "test-cid-123"
        Nothing -> expectationFailure "Failed to decode response"

  it "replays a dead letter message and produces to Kafka" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      initialRequest <- parseRequest ("http://localhost:" <> show port' <> "/dlq/1/replay")
      let request = addAdminAuth initialRequest {method = "POST"}
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeResult = decode @ReplayResult (responseBody response)
      maybeResult `shouldSatisfy` isJust

      case maybeResult of
        Just result -> do
          result.id `shouldBe` 1
          success result `shouldBe` True
          message result `shouldBe` Nothing
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
      let request = addAdminAuth initialRequest {method = "POST"}
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      -- Verify status changed to discarded
      getRequest <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq/1")
      getResponse <- httpLbs getRequest manager
      let maybeDl = decode @DeadLetterResponse (responseBody getResponse)
      case maybeDl of
        Just dl -> status dl `shouldBe` "discarded"
        Nothing -> expectationFailure "Failed to decode response"

  it "returns stats" $ do
    withTestApp $ \port' testApp -> do
      seedDeadLetter testApp

      manager <- newManager defaultManagerSettings
      request <- addAdminAuth <$> parseRequest ("http://localhost:" <> show port' <> "/dlq/stats")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200

      let maybeStats = decode @DLQStats (responseBody response)
      maybeStats `shouldSatisfy` isJust

      case maybeStats of
        Just stats -> do
          stats.total `shouldBe` 1
          stats.pending `shouldBe` 1
          stats.replayed `shouldBe` 0
          stats.discarded `shouldBe` 0
        Nothing -> expectationFailure "Failed to decode stats"

main :: IO ()
main = hspec $ do
  spec
