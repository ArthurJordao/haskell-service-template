module App
  ( App (..),
    HasKafkaProducerHandle (..),
    HasLogContext (..),
    initializeApp,
    runApp,
    app,
  )
where

import Control.Monad.Logger (runStderrLoggingT)
import qualified Data.Map.Strict as Map
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import qualified Ports.Server as Server
import qualified Ports.Consumer as KafkaPort
import Kafka.Producer (KafkaProducer)
import Models.Account (migrateAll)
import Network.Wai.Handler.Warp (run)
import RIO
import Servant
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), correlationIdMiddleware, defaultCorrelationId, extractCorrelationId, logInfoC, unCorrelationId)
import Service.Database (HasDB (..))
import Service.Metrics.Database (recordDatabaseMetricsInternal)
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import qualified Service.Kafka as Kafka
import Service.HttpClient (HttpClient, HasHttpClient (..))
import qualified Service.HttpClient as HttpClient
import Service.Auth (JWTAuthConfig, makeJWTAuthConfig)
import Service.Metrics (Metrics, HasMetrics (..), initMetrics)
import Settings (Settings (..), server)

data App = App
  { appLogFunc :: !LogFunc,
    appLogContext :: !(Map Text Text),
    appSettings :: !Settings,
    appCorrelationId :: !CorrelationId,
    db :: !ConnectionPool,
    kafkaProducer :: !KafkaProducer,
    httpClient :: !HttpClient,
    appMetrics :: !Metrics,
    appJwtConfig :: !JWTAuthConfig
  }

instance HasLogFunc App where
  logFuncL = lens appLogFunc (\x y -> x {appLogFunc = y})

instance HasLogContext App where
  logContextL = lens appLogContext (\x y -> x {appLogContext = y})

instance HasCorrelationId App where
  correlationIdL = lens appCorrelationId (\x y -> x {appCorrelationId = y})

instance Server.HasConfig App Settings where
  settingsL = lens appSettings (\x y -> x {appSettings = y})
  httpSettings = server

instance HasDB App where
  dbL = lens db (\x y -> x {db = y})
  dbRecordQueryMetrics = recordDatabaseMetricsInternal

class HasKafkaProducerHandle env where
  kafkaProducerL :: Lens' env KafkaProducer

instance HasKafkaProducerHandle App where
  kafkaProducerL = lens kafkaProducer (\x y -> x {kafkaProducer = y})

instance HasKafkaProducer App where
  produceKafkaMessage topic key value = do
    producer <- view kafkaProducerL
    cid <- view correlationIdL
    Kafka.produceMessageWithCid producer topic key value cid

instance HasHttpClient App where
  httpClientL = lens httpClient (\x y -> x {httpClient = y})

instance HasMetrics App where
  metricsL = lens appMetrics (\x y -> x {appMetrics = y})

-- OptionalKafkaMetrics and OptionalDatabaseMetrics instances are provided
-- automatically via overlapping instances from Service.Metrics

initializeApp :: Settings -> LogFunc -> IO App
initializeApp settings logFunc = runRIO logFunc $ do
  let dbSettings = database settings
      kafkaSettings = kafka settings

  pool <- liftIO $ Database.createConnectionPool dbSettings

  when (Database.dbAutoMigrate dbSettings) $ do
    logInfo "Running database migrations (DB_AUTO_MIGRATE=true)"
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

  producer <- Kafka.startProducer (KafkaPort.kafkaBroker kafkaSettings)
  client <- HttpClient.initHttpClient
  metrics <- liftIO initMetrics

  let initCid = defaultCorrelationId
      initContext = Map.singleton "cid" (unCorrelationId initCid)
      jwtCfg = makeJWTAuthConfig (jwtPublicKey settings) "user-"

  return
    App
      { appLogFunc = logFunc,
        appLogContext = initContext,
        appSettings = settings,
        appCorrelationId = initCid,
        db = pool,
        kafkaProducer = producer,
        httpClient = client,
        appMetrics = metrics,
        appJwtConfig = jwtCfg
      }

runApp :: App -> IO ()
runApp env = do
  let settings = appSettings env
      serverSettings = server settings
      kafkaSettings = kafka settings

  runRIO env $ do
    let consumerCfg = KafkaPort.consumerConfig kafkaSettings
    race_ (serverThread serverSettings) (Kafka.runConsumerLoop consumerCfg)
  where
    serverThread :: Server.Settings -> RIO App ()
    serverThread serverSettings = do
      appEnv <- ask
      logInfoC $ "Starting HTTP server on port " <> displayShow (Server.httpPort serverSettings)
      liftIO $ run (Server.httpPort serverSettings) (app appEnv)

type AppContext = '[ErrorFormatters, JWTAuthConfig, App]

app :: App -> Application
app baseEnv = correlationIdMiddleware $ \req ->
  let maybeCid = extractCorrelationId req
      cid = fromMaybe (error "CID middleware should always set CID") maybeCid
      cidText = unCorrelationId cid
      env =
        baseEnv
          & correlationIdL
          .~ cid
            & logContextL
          .~ Map.singleton "cid" cidText
   in serveWithContext api (appContext env) (hoistServerWithContext api (Proxy :: Proxy AppContext) (runRIO env) Server.server) req
  where
    api :: Proxy Server.API
    api = Proxy

    appContext :: App -> Context AppContext
    appContext e = Server.jsonErrorFormatters :. appJwtConfig e :. e :. EmptyContext
