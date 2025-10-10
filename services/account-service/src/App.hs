module App
  ( App (..),
    HasKafkaProducerHandle (..),
    HasLogContext (..),
    initializeApp,
    runApp,
    app,
  )
where

import API
import Control.Monad.Logger (runStderrLoggingT)
import qualified Data.Map.Strict as Map
import Database.Persist.Sql (ConnectionPool, runMigration, runSqlPool)
import qualified Handlers.Kafka
import qualified Handlers.Server
import Kafka.Producer (KafkaProducer)
import Models.Account (migrateAll)
import Network.Wai.Handler.Warp (run)
import RIO
import Servant
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), correlationIdMiddleware, defaultCorrelationId, extractCorrelationId, logInfoC, unCorrelationId)
import Service.Database (HasDB (..))
import qualified Service.Database as Database
import Service.Kafka (HasKafkaProducer (..))
import qualified Service.Kafka as Kafka
import Settings (Settings (..), http)

data App = App
  { appLogFunc :: !LogFunc,
    appLogContext :: !(Map Text Text),
    appSettings :: !Settings,
    appCorrelationId :: !CorrelationId,
    db :: !ConnectionPool,
    kafkaProducer :: !KafkaProducer
  }

instance HasLogFunc App where
  logFuncL = lens appLogFunc (\x y -> x {appLogFunc = y})

instance HasLogContext App where
  logContextL = lens appLogContext (\x y -> x {appLogContext = y})

instance HasCorrelationId App where
  correlationIdL = lens appCorrelationId (\x y -> x {appCorrelationId = y})

instance Handlers.Server.HasConfig App Settings where
  settingsL = lens appSettings (\x y -> x {appSettings = y})
  http = http

instance HasDB App where
  dbL = lens db (\x y -> x {db = y})

class HasKafkaProducerHandle env where
  kafkaProducerL :: Lens' env KafkaProducer

instance HasKafkaProducerHandle App where
  kafkaProducerL = lens kafkaProducer (\x y -> x {kafkaProducer = y})

instance HasKafkaProducer App where
  produceKafkaMessage topic key value = do
    producer <- view kafkaProducerL
    cid <- view correlationIdL
    Kafka.produceMessageWithCid producer topic key value cid

initializeApp :: Settings -> LogFunc -> IO App
initializeApp settings logFunc = runRIO logFunc $ do
  let dbSettings = database settings
      kafkaSettings = kafka settings

  pool <- liftIO $ Database.createConnectionPool dbSettings

  when (Database.dbAutoMigrate dbSettings) $ do
    logInfo "Running database migrations (DB_AUTO_MIGRATE=true)"
    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

  producer <- Kafka.startProducer (Handlers.Kafka.kafkaBroker kafkaSettings)

  let initCid = defaultCorrelationId
      initContext = Map.singleton "cid" (unCorrelationId initCid)

  return
    App
      { appLogFunc = logFunc,
        appLogContext = initContext,
        appSettings = settings,
        appCorrelationId = initCid,
        db = pool,
        kafkaProducer = producer
      }

runApp :: App -> IO ()
runApp env = do
  let settings = appSettings env
      httpSettings = http settings
      kafkaSettings = kafka settings

  runRIO env $ do
    let consumerCfg = Handlers.Kafka.consumerConfig kafkaSettings
    consumer <- Kafka.startConsumer consumerCfg

    race_ (serverThread httpSettings) (kafkaThread consumer consumerCfg)
  where
    serverThread :: Handlers.Server.Settings -> RIO App ()
    serverThread httpSettings = do
      appEnv <- ask
      logInfoC $ "Starting HTTP server on port " <> displayShow (Handlers.Server.httpPort httpSettings)
      liftIO $ run (Handlers.Server.httpPort httpSettings) (app appEnv)

    kafkaThread :: Kafka.KafkaConsumer -> Kafka.ConsumerConfig App -> RIO App ()
    kafkaThread consumer consumerCfg = do
      logInfoC "Starting Kafka consumer"
      Kafka.consumerLoop consumer consumerCfg

type AppContext = '[App]

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
   in serveWithContext api (appContext env) (hoistServerWithContext api (Proxy :: Proxy AppContext) (runRIO env) Handlers.Server.server) req
  where
    api :: Proxy API
    api = Proxy

    appContext :: App -> Context AppContext
    appContext e = e :. EmptyContext
