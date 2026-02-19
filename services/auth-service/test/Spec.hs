{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

import Auth.JWT (JWTSettings (..))
import Crypto.JOSE.JWA.JWK (Crv (..), KeyMaterialGenParam (..))
import Crypto.JOSE.JWK (genJWK)
import Control.Monad.Logger (runStderrLoggingT)
import Data.Aeson (decode, encode)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import Models.User (migrateAll)
import Network.HTTP.Client
  ( Manager,
    RequestBody (..),
    Response,
    defaultManagerSettings,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (status200, statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import qualified Ports.Consumer as KafkaPort
import Ports.Server
  ( API,
    AuthTokens (..),
    HasConfig (..),
    LoginRequest (..),
    LogoutRequest (..),
    RefreshRequest (..),
    RegisterRequest (..),
  )
import qualified Ports.Server as Server
import RIO hiding (Handler)
import Control.Monad.Except (ExceptT (..))
import Servant (Proxy (..))
import Servant.Server (Handler (..), ServerError, hoistServer, serve)
import Service.CorrelationId
  ( CorrelationId (..),
    HasCorrelationId (..),
    HasLogContext (..),
    defaultCorrelationId,
  )
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import Service.Metrics (HasMetrics (..), Metrics, initMetrics)
import Settings (Settings (..))
import Test.Hspec

-- ============================================================================
-- Test Environment
-- ============================================================================

data TestApp = TestApp
  { testLogFunc :: !LogFunc,
    testLogContext :: !(Map Text Text),
    testSettings :: !Settings,
    testCorrelationId :: !CorrelationId,
    testDb :: !ConnectionPool,
    testMetrics :: !Metrics
  }

instance HasLogFunc TestApp where
  logFuncL = lens testLogFunc (\x y -> x {testLogFunc = y})

instance HasLogContext TestApp where
  logContextL = lens testLogContext (\x y -> x {testLogContext = y})

instance HasCorrelationId TestApp where
  correlationIdL = lens testCorrelationId (\x y -> x {testCorrelationId = y})

-- server / jwt are the Settings record field accessors
instance HasConfig TestApp Settings where
  settingsL = lens testSettings (\x y -> x {testSettings = y})
  httpSettings = server
  jwtSettings = jwt

instance HasDB TestApp where
  dbL = lens testDb (\x y -> x {testDb = y})

instance HasKafkaProducer TestApp where
  produceKafkaMessage _ _ _ = return ()

instance HasMetrics TestApp where
  metricsL = lens testMetrics (\x y -> x {testMetrics = y})

-- ============================================================================
-- Fixtures
-- ============================================================================

-- Each test gets an isolated in-memory database and fresh app.
withTestApp :: (Int -> IO ()) -> IO ()
withTestApp action = do
  testKey <- genJWK (ECGenParam P_256)
  let testJwtSettings =
        JWTSettings
          { jwtPrivateKey = testKey,
            jwtAccessTokenExpirySeconds = 900,
            jwtRefreshTokenExpiryDays = 7,
            jwtAdminEmails = []
          }
  let dbSettings =
        Database.Settings
          { Database.dbType = Database.SQLite,
            Database.dbConnectionString = ":memory:",
            Database.dbPoolSize = 1,
            Database.dbAutoMigrate = False
          }
      testSettings =
        Settings
          { server = Server.Settings {Server.httpPort = 0, Server.httpEnvironment = "test"},
            kafka =
              KafkaPort.Settings
                { KafkaPort.kafkaBroker = "localhost:9092",
                  KafkaPort.kafkaGroupId = "auth-test",
                  KafkaPort.kafkaDeadLetterTopic = "DEADLETTER",
                  KafkaPort.kafkaMaxRetries = 3
                },
            database = dbSettings,
            jwt = testJwtSettings,
            corsOrigins = []
          }
  logOptions <- logOptionsHandle stderr False
  withLogFunc logOptions $ \logFunc -> do
    pool <- Database.createConnectionPool dbSettings
    runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
    metrics <- initMetrics
    let testApp =
          TestApp
            { testLogFunc = logFunc,
              testLogContext = Map.empty,
              testSettings = testSettings,
              testCorrelationId = defaultCorrelationId,
              testDb = pool,
              testMetrics = metrics
            }
    testWithApplication (pure $ appToWai testApp) action

appToWai :: TestApp -> Application
appToWai env =
  serve (Proxy @API) $
    hoistServer (Proxy @API) toHandler Server.server
  where
    -- throwM in RIO throws ServerError as an IO exception.
    -- Handler = ExceptT ServerError IO, so we catch and re-route it.
    toHandler :: forall a. RIO TestApp a -> Handler a
    toHandler action =
      Handler $ ExceptT $
        (Right <$> runRIO env action)
          `catch` (\(e :: ServerError) -> return (Left e))

-- ============================================================================
-- HTTP Helpers
-- ============================================================================

postJSON :: Manager -> String -> BSL.ByteString -> IO (Response BSL.ByteString)
postJSON mgr url body = do
  req <- parseRequest url
  httpLbs
    req
      { method = "POST",
        requestBody = RequestBodyLBS body,
        requestHeaders = [("Content-Type", "application/json")]
      }
    mgr

baseUrl :: Int -> String
baseUrl port = "http://localhost:" <> show port

registerUser :: Manager -> Int -> Text -> Text -> IO (Response BSL.ByteString)
registerUser mgr port email pass =
  postJSON mgr (baseUrl port <> "/auth/register") (encode (RegisterRequest email pass))

loginUser :: Manager -> Int -> Text -> Text -> IO (Response BSL.ByteString)
loginUser mgr port email pass =
  postJSON mgr (baseUrl port <> "/auth/login") (encode (LoginRequest email pass))

-- ============================================================================
-- Tests
-- ============================================================================

spec :: Spec
spec = around withTestApp $ do
  describe "GET /status" $ do
    it "returns 200 OK" $ \port -> do
      mgr <- newManager defaultManagerSettings
      req <- parseRequest (baseUrl port <> "/status")
      resp <- httpLbs req mgr
      responseStatus resp `shouldBe` status200

  describe "POST /auth/register" $ do
    it "creates a new user and returns JWT tokens" $ \port -> do
      mgr <- newManager defaultManagerSettings
      resp <- registerUser mgr port "alice@example.com" "hunter2"
      responseStatus resp `shouldBe` status200
      let mTokens = decode @AuthTokens (responseBody resp)
      mTokens `shouldSatisfy` isJust
      case mTokens of
        Nothing -> expectationFailure "Failed to decode AuthTokens"
        Just tokens -> do
          accessToken tokens `shouldNotBe` ""
          tokens.refreshToken `shouldNotBe` ""
          tokenType tokens `shouldBe` "Bearer"
          expiresIn tokens `shouldBe` 900

    it "returns 409 when the email is already registered" $ \port -> do
      mgr <- newManager defaultManagerSettings
      _ <- registerUser mgr port "bob@example.com" "pass1"
      resp <- registerUser mgr port "bob@example.com" "pass2"
      statusCode (responseStatus resp) `shouldBe` 409

  describe "POST /auth/login" $ do
    it "issues tokens for valid credentials" $ \port -> do
      mgr <- newManager defaultManagerSettings
      _ <- registerUser mgr port "charlie@example.com" "secret"
      resp <- loginUser mgr port "charlie@example.com" "secret"
      responseStatus resp `shouldBe` status200
      decode @AuthTokens (responseBody resp) `shouldSatisfy` isJust

    it "returns 401 for a wrong password" $ \port -> do
      mgr <- newManager defaultManagerSettings
      _ <- registerUser mgr port "dave@example.com" "correct"
      resp <- loginUser mgr port "dave@example.com" "wrong"
      statusCode (responseStatus resp) `shouldBe` 401

    it "returns 401 for an unknown email" $ \port -> do
      mgr <- newManager defaultManagerSettings
      resp <- loginUser mgr port "nobody@example.com" "pass"
      statusCode (responseStatus resp) `shouldBe` 401

  describe "POST /auth/refresh" $ do
    it "issues a new access token given a valid refresh token" $ \port -> do
      mgr <- newManager defaultManagerSettings
      regResp <- registerUser mgr port "eve@example.com" "pass"
      let Just tokens = decode @AuthTokens (responseBody regResp)
      resp <- postJSON mgr (baseUrl port <> "/auth/refresh") (encode (RefreshRequest (tokens.refreshToken)))
      responseStatus resp `shouldBe` status200
      decode @AuthTokens (responseBody resp) `shouldSatisfy` isJust

    it "returns 401 for a malformed token" $ \port -> do
      mgr <- newManager defaultManagerSettings
      resp <- postJSON mgr (baseUrl port <> "/auth/refresh") (encode (RefreshRequest "not.a.valid.jwt"))
      statusCode (responseStatus resp) `shouldBe` 401

  describe "POST /auth/logout" $ do
    it "revokes the refresh token so it cannot be reused" $ \port -> do
      mgr <- newManager defaultManagerSettings
      regResp <- registerUser mgr port "frank@example.com" "pass"
      let Just tokens = decode @AuthTokens (responseBody regResp)
          rt = tokens.refreshToken
      logoutResp <- postJSON mgr (baseUrl port <> "/auth/logout") (encode (LogoutRequest rt))
      responseStatus logoutResp `shouldBe` status200
      -- The revoked token must no longer be accepted
      refreshResp <- postJSON mgr (baseUrl port <> "/auth/refresh") (encode (RefreshRequest rt))
      statusCode (responseStatus refreshResp) `shouldBe` 401

    it "treats an expired or invalid token as already-logged-out (200)" $ \port -> do
      mgr <- newManager defaultManagerSettings
      resp <- postJSON mgr (baseUrl port <> "/auth/logout") (encode (LogoutRequest "invalid.token"))
      -- logout is idempotent; invalid tokens are silently accepted
      responseStatus resp `shouldBe` status200

main :: IO ()
main = hspec spec
