{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

import Control.Monad.Except (ExceptT (..))
import Control.Monad.Logger (runStderrLoggingT)
import Crypto.JOSE.JWK (JWK)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Database.Persist (Entity (..), selectList)
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import Domain.Notifications
  ( HasNotificationDir (..),
    HasTemplateCache (..),
    NotificationChannel (..),
    NotificationMessage (..),
    NotificationVariable (..),
    processNotification,
  )
import DB.SentNotification (SentNotification (..), migrateAll)
import Network.HTTP.Client
  ( defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    responseStatus,
  )
import Network.HTTP.Types.Status (status200)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import qualified Ports.Consumer as KafkaPort
import Ports.Server (API, HasConfig (..))
import qualified Ports.Server as Server
import RIO hiding (Handler)
import Servant (Context (..), ErrorFormatters, Proxy (..))
import Servant.Server (Handler (..), ServerError, hoistServerWithContext, serveWithContext)
import Service.Auth (JWTAuthConfig, makeJWTAuthConfig)
import Service.CorrelationId
  ( CorrelationId (..),
    HasCorrelationId (..),
    HasLogContext (..),
    defaultCorrelationId,
  )
import Service.Database (HasDB (..), runSqlPoolWithCid)
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import Service.Server (jsonErrorFormatters)
import Settings (Settings (..))
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Text.Mustache (Template, compileTemplate)

-- ============================================================================
-- Test Environment
-- ============================================================================

data TestApp = TestApp
  { testLogFunc :: LogFunc,
    testLogContext :: (Map Text Text),
    testSettings :: Settings,
    testCorrelationId :: CorrelationId,
    testTemplates :: (Map Text Template),
    testNotificationsDir :: FilePath,
    testDb :: ConnectionPool,
    testJwtConfig :: JWTAuthConfig
  }

instance HasLogFunc TestApp where
  logFuncL = lens testLogFunc (\x y -> x {testLogFunc = y})

instance HasLogContext TestApp where
  logContextL = lens testLogContext (\x y -> x {testLogContext = y})

instance HasCorrelationId TestApp where
  correlationIdL = lens testCorrelationId (\x y -> x {testCorrelationId = y})

instance HasConfig TestApp Settings where
  settingsL = lens testSettings (\x y -> x {testSettings = y})
  httpSettings = server

instance HasTemplateCache TestApp where
  templateCacheL = lens testTemplates (\x y -> x {testTemplates = y})

instance HasNotificationDir TestApp where
  notificationDirL = lens testNotificationsDir (\x y -> x {testNotificationsDir = y})

instance HasDB TestApp where
  dbL = lens testDb (\x y -> x {testDb = y})

instance HasKafkaProducer TestApp where
  produceKafkaMessage _ _ _ = return ()

-- ============================================================================
-- Fixtures
-- ============================================================================

-- | A minimal EC P-256 JWK (public key) used for wiring Servant context in tests.
-- The /status route doesn't validate JWTs, so the actual key content doesn't matter.
testJWK :: JWK
testJWK =
  case Aeson.eitherDecodeStrict' testJWKBytes of
    Right jwk -> jwk
    Left err -> error $ "Test JWK parse failed: " <> err
  where
    testJWKBytes =
      "{\"kty\":\"EC\",\"crv\":\"P-256\"\
      \,\"x\":\"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU\"\
      \,\"y\":\"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0\"}"

-- | Compile a template at test time; fails loudly on a parse error.
unsafeCompile :: String -> Text -> Template
unsafeCompile name src =
  case compileTemplate name src of
    Left err -> error $ "Test template compile error: " <> show err
    Right tmpl -> tmpl

-- | In-memory templates used in tests. Mirrors resources/templates/.
-- Use actual Mustache variables so missing-variable tests work correctly.
testTemplateCache :: Map Text Template
testTemplateCache =
  Map.fromList
    [ ("welcome_email", unsafeCompile "welcome_email" "Hello {{name}}, welcome! Your email: {{email}}")
    , ("password_reset", unsafeCompile "password_reset" "Reset password for {{name}} ({{email}}) at {{resetUrl}}")
    ]

-- | Build an in-memory SQLite connection pool and run migrations.
makeTestPool :: IO ConnectionPool
makeTestPool = do
  pool <-
    Database.createConnectionPool
      Database.Settings
        { Database.dbType = Database.SQLite,
          Database.dbConnectionString = ":memory:",
          Database.dbPoolSize = 1,
          Database.dbAutoMigrate = False
        }
  runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
  return pool

-- | Run an action with a fully initialised TestApp in a temporary notifications directory.
withDomainApp :: (TestApp -> IO ()) -> IO ()
withDomainApp action =
  withSystemTempDirectory "notif-test" $ \tmpDir -> do
    pool <- makeTestPool
    logOptions <- logOptionsHandle stderr False
    withLogFunc logOptions $ \logFunc ->
      action
        TestApp
          { testLogFunc = logFunc,
            testLogContext = Map.empty,
            testSettings = error "unused",
            testCorrelationId = defaultCorrelationId,
            testTemplates = testTemplateCache,
            testNotificationsDir = tmpDir,
            testDb = pool,
            testJwtConfig = makeJWTAuthConfig testJWK "user-"
          }

withTestApp :: (Int -> TestApp -> IO ()) -> IO ()
withTestApp action =
  withSystemTempDirectory "notif-test" $ \tmpDir -> do
    pool <- makeTestPool
    let jwtCfg = makeJWTAuthConfig testJWK "user-"
    let testSettings =
          Settings
            { server = Server.Settings {Server.httpPort = 0, Server.httpEnvironment = "test"},
              kafka =
                KafkaPort.Settings
                  { KafkaPort.kafkaBroker = "localhost:9092",
                    KafkaPort.kafkaGroupId = "notification-service-test",
                    KafkaPort.kafkaDeadLetterTopic = "DEADLETTER",
                    KafkaPort.kafkaMaxRetries = 3
                  },
              db =
                Database.Settings
                  { Database.dbType = Database.SQLite,
                    Database.dbConnectionString = ":memory:",
                    Database.dbPoolSize = 1,
                    Database.dbAutoMigrate = False
                  },
              templatesDir = "resources/templates",
              notificationsDir = tmpDir,
              jwtPublicKey = testJWK,
              corsOrigins = []
            }
    logOptions <- logOptionsHandle stderr False
    withLogFunc logOptions $ \logFunc -> do
      let testApp =
            TestApp
              { testLogFunc = logFunc,
                testLogContext = Map.empty,
                testSettings = testSettings,
                testCorrelationId = defaultCorrelationId,
                testTemplates = testTemplateCache,
                testNotificationsDir = tmpDir,
                testDb = pool,
                testJwtConfig = jwtCfg
              }
      testWithApplication (pure $ appToWai testApp) $ \port -> action port testApp

type TestAppContext = '[ErrorFormatters, JWTAuthConfig, TestApp]

appToWai :: TestApp -> Application
appToWai env =
  serveWithContext (Proxy @API) ctx $
    hoistServerWithContext (Proxy @API) (Proxy @TestAppContext) toHandler Server.server
  where
    ctx = jsonErrorFormatters :. testJwtConfig env :. env :. EmptyContext
    toHandler :: forall a. RIO TestApp a -> Handler a
    toHandler action =
      Handler $ ExceptT $
        (Right <$> runRIO env action)
          `catch` (\(e :: ServerError) -> return (Left e))

-- ============================================================================
-- Tests
-- ============================================================================

spec :: Spec
spec = do
  describe "Domain.Notifications.processNotification" $ do
    it "renders a template, writes a file, and persists a DB record" $
      withDomainApp $ \testApp -> do
        let msg =
              NotificationMessage
                { templateName = "welcome_email",
                  variables =
                    [ NotificationVariable "name" "Alice",
                      NotificationVariable "email" "alice@example.com"
                    ],
                  channel = Email "alice@example.com"
                }
        runRIO testApp (processNotification msg)

        -- File was written
        files <- listDirectory (testNotificationsDir testApp)
        case files of
          [file] -> do
            content <- T.unpack <$> readFileUtf8 (testNotificationsDir testApp </> file)
            content `shouldContain` "alice@example.com"
            content `shouldContain` "Alice"
          _ -> expectationFailure $ "Expected 1 notification file, got " <> show (length files)

        -- DB record was persisted
        records :: [Entity SentNotification] <-
          runRIO testApp $ do
            pool <- view dbL
            runSqlPoolWithCid (selectList [] []) pool
        case records of
          [r] -> do
            let SentNotification{..} = entityVal r
            sentNotificationTemplateName `shouldBe` "welcome_email"
            sentNotificationChannelType `shouldBe` "email"
            sentNotificationRecipient `shouldBe` "alice@example.com"
          _ -> expectationFailure $ "Expected 1 DB record, got " <> show (length records)

    it "fails when a required variable is missing" $
      withDomainApp $ \testApp -> do
        let msg =
              NotificationMessage
                { templateName = "welcome_email",
                  variables = [NotificationVariable "name" "Alice"], -- missing "email"
                  channel = Email "alice@example.com"
                }
        result :: Either SomeException () <- try $ runRIO testApp (processNotification msg)
        result `shouldSatisfy` isLeft

    it "fails when the template does not exist" $
      withDomainApp $ \testApp -> do
        let msg =
              NotificationMessage
                { templateName = "nonexistent_template",
                  variables = [NotificationVariable "name" "Alice"],
                  channel = Email "alice@example.com"
                }
        result :: Either SomeException () <- try $ runRIO testApp (processNotification msg)
        result `shouldSatisfy` isLeft

  describe "GET /status" $ do
    it "returns 200 OK" $
      withTestApp $ \port _ -> do
        mgr <- newManager defaultManagerSettings
        req <- parseRequest ("http://localhost:" <> show port <> "/status")
        resp <- httpLbs req mgr
        responseStatus resp `shouldBe` status200

main :: IO ()
main = hspec spec
