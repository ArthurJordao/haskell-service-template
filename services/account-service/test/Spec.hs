{-# LANGUAGE FlexibleContexts #-}

import Control.Monad.Except (ExceptT (..))
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Data.Text.Encoding (encodeUtf8)
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import Kafka.Consumer (TopicName (..))
import DB.Account (Account (..), migrateAll)
import Network.HTTP.Client
  ( Manager,
    Response,
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (status200, statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import Ports.Server (API)
import Types.In.UserRegistered (UserRegisteredEvent (..))
import qualified Ports.Consumer as KafkaPort
import qualified Ports.Server as Server
import RIO hiding (Handler)
import RIO.Text (pack, unpack)
import qualified RIO.Text as T
import qualified RIO.Seq as Seq
import Servant (Proxy (..), err500, errBody)
import Servant.Server (Context (..), Handler (..), ServerError, hoistServerWithContext, serveWithContext)
import Service.Auth (AccessTokenClaims (..), JWTAuthConfig (..))
import Service.CorrelationId
  ( CorrelationId (..),
    HasCorrelationId (..),
    HasLogContext (..),
    defaultCorrelationId,
    logInfoC,
    unCorrelationId,
  )
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.HttpClient (HasHttpClient (..), HttpClient)
import qualified Service.HttpClient as HttpClient
import Service.Kafka (HasKafkaProducer (..))
import Service.Metrics (HasMetrics (..), Metrics, initMetrics)
import Service.Test.HttpClient
  ( MockHttpState,
    MockRequest (..),
    assertRequestMade,
    getRequests,
    mockResponse,
    newMockHttpState,
  )
import qualified Service.Test.HttpClient as MockHttp
import Service.Test.Kafka
  ( MockConsumer (..),
    MockKafkaState (..),
    MockProducer (..),
    QueuedMessage (..),
    consumedMessages,
    mockProduceMessage,
    newMockKafkaState,
    processAllMessages,
  )
import qualified Data.Text.Encoding as TE
import Crypto.JOSE.JWA.JWK (Crv (..), KeyMaterialGenParam (..))
import Crypto.JOSE.JWK (genJWK)
import Settings (Settings (..))
import Servant.Server.Generic (AsServerT)
import Test.Hspec

-- ============================================================================
-- Test Environment
-- ============================================================================

data TestApp = TestApp
  { testAppLogFunc :: !LogFunc,
    testAppLogContext :: !(Map Text Text),
    testAppSettings :: !Settings,
    testAppCorrelationId :: !CorrelationId,
    testAppDb :: !ConnectionPool,
    testAppMockKafka :: !MockKafkaState,
    testAppHttpClient :: !HttpClient,
    testAppMockHttp :: !MockHttpState,
    testAppMetrics :: !Metrics
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

instance HasHttpClient TestApp where
  httpClientL = lens testAppHttpClient (\x y -> x {testAppHttpClient = y})

instance HasMetrics TestApp where
  metricsL = lens testAppMetrics (\x y -> x {testAppMetrics = y})

class HasMockHttp env where
  mockHttpL :: Lens' env MockHttpState

instance HasMockHttp TestApp where
  mockHttpL = lens testAppMockHttp (\x y -> x {testAppMockHttp = y})

-- ============================================================================
-- Test server (overrides external post handler with mock)
-- ============================================================================

testExternalPostHandler ::
  (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasMockHttp env) =>
  Int ->
  RIO env Server.ExternalPost
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

testServer ::
  ( HasLogFunc env,
    HasLogContext env,
    HasCorrelationId env,
    Server.HasConfig env Settings,
    HasDB env,
    HasHttpClient env,
    HasMockHttp env,
    HasMetrics env
  ) =>
  Server.Routes (AsServerT (RIO env))
testServer =
  let realServer = Server.server
   in realServer {Server.getExternalPost = testExternalPostHandler}

-- ============================================================================
-- Test JWT config (mock validate — no real JWT signing needed)
-- ============================================================================

-- | A mock JWTAuthConfig that maps known bearer token strings to claims.
-- "token-user-N" → subject "user-N".
mockJwtConfig :: JWTAuthConfig
mockJwtConfig =
  JWTAuthConfig
    { jwtAuthValidate = \token ->
        let userPrefix  = "token-user-"
            adminPrefix = "token-admin-"
         in if userPrefix `T.isPrefixOf` token
              then do
                let uid = T.drop (T.length userPrefix) token
                return $
                  Right
                    AccessTokenClaims
                      { atcSubject = "user-" <> uid,
                        atcEmail = Just (uid <> "@example.com"),
                        atcJti = "jti-" <> uid,
                        atcScopes = ["read:accounts:own"]
                      }
              else if adminPrefix `T.isPrefixOf` token
                then do
                  let uid = T.drop (T.length adminPrefix) token
                  return $
                    Right
                      AccessTokenClaims
                        { atcSubject = "user-" <> uid,
                          atcEmail = Just (uid <> "@example.com"),
                          atcJti = "jti-admin-" <> uid,
                          atcScopes = ["read:accounts:own", "admin"]
                        }
                else return (Left "invalid token"),
      jwtAuthSubjectPrefix = "user-"
    }

type TestAppContext = '[JWTAuthConfig]

-- ============================================================================
-- App setup
-- ============================================================================

withTestApp :: (Int -> TestApp -> IO ()) -> IO ()
withTestApp action = do
  testKey <- genJWK (ECGenParam P_256)
  let testSettings =
        Settings
          { server = Server.Settings {Server.httpPort = 8080, Server.httpEnvironment = "test"},
            kafka =
              KafkaPort.Settings
                { KafkaPort.kafkaBroker = "localhost:9092",
                  KafkaPort.kafkaGroupId = "test-group",
                  KafkaPort.kafkaDeadLetterTopic = "DEADLETTER",
                  KafkaPort.kafkaMaxRetries = 3
                },
            database =
              Database.Settings
                { Database.dbType = Database.SQLite,
                  Database.dbConnectionString = ":memory:",
                  Database.dbPoolSize = 1,
                  Database.dbAutoMigrate = True
                },
            jwtPublicKey = testKey
          }
  logOptions <- logOptionsHandle stderr True
  withLogFunc logOptions $ \logFunc -> runRIO logFunc $ do
    mockKafkaState <- liftIO newMockKafkaState
    mockHttpState <- liftIO newMockHttpState
    pool <- liftIO $ Database.createConnectionPool testSettings.database
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
    httpClient <- HttpClient.initHttpClient
    metrics <- liftIO initMetrics

    let testApp =
          TestApp
            { testAppLogFunc = logFunc,
              testAppLogContext = Map.empty,
              testAppSettings = testSettings,
              testAppCorrelationId = defaultCorrelationId,
              testAppDb = pool,
              testAppMockKafka = mockKafkaState,
              testAppHttpClient = httpClient,
              testAppMockHttp = mockHttpState,
              testAppMetrics = metrics
            }

    liftIO $ testWithApplication (pure $ testAppToWai testApp) $ \port' -> action port' testApp

testAppToWai :: TestApp -> Application
testAppToWai env =
  serveWithContext (Proxy @API) (mockJwtConfig :. EmptyContext) $
    hoistServerWithContext
      (Proxy @API)
      (Proxy @TestAppContext)
      toHandler
      testServer
  where
    toHandler :: forall a. RIO TestApp a -> Handler a
    toHandler action =
      Handler $ ExceptT $
        (Right <$> runRIO env action)
          `catch` (\(e :: ServerError) -> return (Left e))

-- ============================================================================
-- HTTP helpers
-- ============================================================================

getJSON :: Manager -> String -> [(String, String)] -> IO (Response BSL.ByteString)
getJSON mgr url headers = do
  req <- parseRequest url
  httpLbs
    req
      { requestHeaders = map (\(k, v) -> (fromString k, fromString v)) headers
      }
    mgr

baseUrl :: Int -> String
baseUrl port = "http://localhost:" <> show port

-- | Create an account by publishing a user-registered Kafka event and processing it.
setupAccount :: TestApp -> Int64 -> Text -> IO ()
setupAccount testApp uid email = runRIO testApp $ do
  let mockKafka = testAppMockKafka testApp
      event = UserRegisteredEvent {userId = uid, email = email}
      consumerCfg = KafkaPort.consumerConfig (Settings.kafka (testAppSettings testApp))
  mockProduceMessage (MockProducer mockKafka) (TopicName "user-registered") Nothing event
  processAllMessages (MockConsumer mockKafka) consumerCfg

-- ============================================================================
-- Tests
-- ============================================================================

spec :: Spec
spec = describe "Server" $ do
  it "respond with 200 on status" $ do
    withTestApp $ \port' _ -> do
      manager <- newManager defaultManagerSettings
      request <- parseRequest (baseUrl port' <> "/status")
      response <- httpLbs request manager
      responseStatus response `shouldBe` status200
      responseBody response `shouldBe` "\"OK\""

  it "fetch external post via HTTP client (mocked)" $ do
    withTestApp $ \port' testApp -> do
      let mockHttpState = testAppMockHttp testApp

      let mockPost =
            Server.ExternalPost
              { Server.userId = 1,
                Server.id = 1,
                Server.title = "Mock Post Title",
                Server.body = "Mock post body content"
              }
      mockResponse mockHttpState "GET" "https://jsonplaceholder.typicode.com/posts/1" 200 (encode mockPost)

      manager <- newManager defaultManagerSettings

      request <- parseRequest (baseUrl port' <> "/external/posts/1")
      response <- httpLbs request manager

      responseStatus response `shouldBe` status200

      let maybePost = decode @Server.ExternalPost (responseBody response)
      maybePost `shouldSatisfy` isJust

      case maybePost of
        Just post -> do
          Server.id post `shouldBe` 1
          Server.userId post `shouldBe` 1
          Server.title post `shouldBe` "Mock Post Title"
          Server.body post `shouldBe` "Mock post body content"
        Nothing -> expectationFailure "Failed to decode ExternalPost response"

      requests <- getRequests mockHttpState

      when (Seq.length requests == 0) $
        expectationFailure "No HTTP requests were recorded in mock"

      Seq.length requests `shouldBe` 1

      case Seq.viewl requests of
        req Seq.:< _ -> do
          mrMethod req `shouldBe` "GET"
          mrUrl req `shouldBe` "https://jsonplaceholder.typicode.com/posts/1"
      wasMade <- assertRequestMade mockHttpState "GET" "https://jsonplaceholder.typicode.com/posts/1"
      wasMade `shouldBe` True

      requests' <- getRequests mockHttpState
      case Seq.viewl requests' of
        req Seq.:< _ -> do
          let hasCorrelationId = any (\(name, _) -> name == "X-Correlation-Id") (mrHeaders req)
          hasCorrelationId `shouldBe` True
        Seq.EmptyL -> expectationFailure "No requests were recorded"

  it "creates account automatically on user-registered Kafka event" $ do
    withTestApp $ \port' testApp -> do
      setupAccount testApp 42 "eve@example.com"

      -- Account is the first inserted row so its DB primary key is 1.
      -- The bearer token carries the auth user ID (42), which must match account.authUserId.
      manager <- newManager defaultManagerSettings
      req <- parseRequest (baseUrl port' <> "/accounts/1")
      resp <-
        httpLbs
          req {requestHeaders = [("Authorization", "Bearer token-user-42")]}
          manager
      statusCode (responseStatus resp) `shouldBe` 200

  describe "GET /accounts/:id (RequireOwner)" $ do
    it "returns 200 when JWT subject matches the account ID" $ do
      withTestApp $ \port' testApp -> do
        manager <- newManager defaultManagerSettings

        setupAccount testApp 1 "alice@example.com"

        req <- parseRequest (baseUrl port' <> "/accounts/1")
        resp <-
          httpLbs
            req {requestHeaders = [("Authorization", "Bearer token-user-1")]}
            manager

        statusCode (responseStatus resp) `shouldBe` 200

    it "returns 403 when JWT subject belongs to a different user" $ do
      withTestApp $ \port' testApp -> do
        manager <- newManager defaultManagerSettings

        setupAccount testApp 1 "bob@example.com"

        -- "token-user-99" → subject "user-99" → does NOT match "user-1"
        req <- parseRequest (baseUrl port' <> "/accounts/1")
        resp <-
          httpLbs
            req {requestHeaders = [("Authorization", "Bearer token-user-99")]}
            manager

        statusCode (responseStatus resp) `shouldBe` 403

    it "returns 401 when no Authorization header is present" $ do
      withTestApp $ \port' _ -> do
        manager <- newManager defaultManagerSettings
        req <- parseRequest (baseUrl port' <> "/accounts/1")
        resp <- httpLbs req manager
        statusCode (responseStatus resp) `shouldBe` 401

    it "returns 401 when the token is invalid" $ do
      withTestApp $ \port' _ -> do
        manager <- newManager defaultManagerSettings
        req <- parseRequest (baseUrl port' <> "/accounts/1")
        resp <-
          httpLbs
            req {requestHeaders = [("Authorization", "Bearer not-a-valid-token")]}
            manager
        statusCode (responseStatus resp) `shouldBe` 401

    it "returns 200 for an admin token belonging to a different user" $ do
      withTestApp $ \port' testApp -> do
        manager <- newManager defaultManagerSettings

        setupAccount testApp 1 "carol@example.com"

        -- "token-admin-99" is not the owner (user-1) but carries the "admin" scope
        req <- parseRequest (baseUrl port' <> "/accounts/1")
        resp <-
          httpLbs
            req {requestHeaders = [("Authorization", "Bearer token-admin-99")]}
            manager

        statusCode (responseStatus resp) `shouldBe` 200

main :: IO ()
main = hspec spec
