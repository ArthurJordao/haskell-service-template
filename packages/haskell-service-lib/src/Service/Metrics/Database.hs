module Service.Metrics.Database
  ( DatabaseMetrics (..),
    HasDatabaseMetrics (..),
    initDatabaseMetrics,
    runDBWithMetrics,
    exportDatabaseMetrics,
    recordDatabaseMetricsInternal,
  )
where

import Control.Monad.Logger (LoggingT, runLoggingT)
import qualified Data.Map.Strict as Map
import Data.Pool (withResource)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import qualified Data.Text as T
import Database.Persist.Sql (ConnectionPool, SqlBackend)
import GHC.Conc (unsafeIOToSTM)
import RIO
import Service.Metrics.Core

-- ============================================================================
-- Database Metrics Data Structure
-- ============================================================================

data DatabaseMetrics = DatabaseMetrics
  { dbQueryDuration :: !(Map Text Histogram),
    -- Key: operation
    dbConnectionsActive :: !Gauge,
    dbConnectionsIdle :: !Gauge,
    dbQueryErrors :: !(Map Text Counter)
    -- Key: error_type
  }

class HasDatabaseMetrics env where
  databaseMetricsL :: Lens' env DatabaseMetrics

-- ============================================================================
-- Initialization
-- ============================================================================

initDatabaseMetrics :: IO DatabaseMetrics
initDatabaseMetrics = do
  dbConnActive <- newGauge
  dbConnIdle <- newGauge

  return
    DatabaseMetrics
      { dbQueryDuration = Map.empty,
        dbConnectionsActive = dbConnActive,
        dbConnectionsIdle = dbConnIdle,
        dbQueryErrors = Map.empty
      }

-- ============================================================================
-- Database Instrumentation
-- ============================================================================

runDBWithMetrics ::
  (HasDatabaseMetrics env, HasLogFunc env, MonadUnliftIO m, MonadReader env m) =>
  ReaderT SqlBackend (LoggingT m) a ->
  ConnectionPool ->
  m a
runDBWithMetrics action pool = do
  metrics <- view databaseMetricsL

  -- Time the query
  start <- liftIO getCurrentTime
  result <- tryAny $ runDBAction action pool
  end <- liftIO getCurrentTime

  let duration = realToFrac $ diffUTCTime end start
      operation = "query" -- Could be enhanced to detect SELECT/INSERT/UPDATE/DELETE

  -- Get or create histogram for this operation
  histogram <- liftIO $ atomically $ do
    case Map.lookup operation (dbQueryDuration metrics) of
      Just h -> return h
      Nothing -> unsafeIOToSTM $ newHistogram defaultBuckets

  liftIO $ observeHistogram histogram duration

  case result of
    Left err -> do
      -- Record error
      let errorType = classifyError err
      errorCounter <- liftIO $ atomically $ do
        case Map.lookup errorType (dbQueryErrors metrics) of
          Just c -> return c
          Nothing -> unsafeIOToSTM newCounter
      liftIO $ incCounter errorCounter
      throwIO err
    Right val -> return val

runDBAction ::
  (MonadUnliftIO m) =>
  ReaderT SqlBackend (LoggingT m) a ->
  ConnectionPool ->
  m a
runDBAction action pool =
  withRunInIO $ \runInIO ->
    withResource pool $ \backend ->
      runInIO $ runLoggingT (runReaderT action backend) $ \_ _ _ _ ->
        pure ()

classifyError :: SomeException -> Text
classifyError ex = T.pack $ take 50 $ show ex

-- Overlapping instance is defined in Service.Metrics to avoid conflicts

-- ============================================================================
-- Internal Helper for Metrics Recording
-- ============================================================================

recordDatabaseMetricsInternal ::
  (HasDatabaseMetrics env, HasLogFunc env) =>
  Text ->
  UTCTime ->
  UTCTime ->
  Either SomeException a ->
  RIO env ()
recordDatabaseMetricsInternal operation start end result = do
  metrics <- view databaseMetricsL
  let duration = realToFrac $ diffUTCTime end start

  -- Record duration histogram
  histogram <- liftIO $ atomically $ do
    case Map.lookup operation (dbQueryDuration metrics) of
      Just h -> return h
      Nothing -> unsafeIOToSTM $ newHistogram defaultBuckets
  liftIO $ observeHistogram histogram duration

  -- Record errors
  case result of
    Left err -> do
      let errorType = classifyError err
      errorCounter <- liftIO $ atomically $ do
        case Map.lookup errorType (dbQueryErrors metrics) of
          Just c -> return c
          Nothing -> unsafeIOToSTM newCounter
      liftIO $ incCounter errorCounter
    Right _ -> return ()

-- ============================================================================
-- Metrics Export
-- ============================================================================

exportDatabaseMetrics :: DatabaseMetrics -> IO [Text]
exportDatabaseMetrics metrics = do
  activeConns <- readTVarIO $ case dbConnectionsActive metrics of Gauge tvar -> tvar
  idleConns <- readTVarIO $ case dbConnectionsIdle metrics of Gauge tvar -> tvar

  queryErrors <- forM (Map.toList $ dbQueryErrors metrics) $ \(errorType, Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "db_query_errors_total{error_type=\"" <> errorType <> "\"} " <> T.pack (show count)

  return $
    ["# HELP db_connections_active Active database connections", "# TYPE db_connections_active gauge", "db_connections_active " <> T.pack (show activeConns)]
      <> ["# HELP db_connections_idle Idle database connections", "# TYPE db_connections_idle gauge", "db_connections_idle " <> T.pack (show idleConns)]
      <> ["# HELP db_query_errors_total Database query errors", "# TYPE db_query_errors_total counter"]
      <> queryErrors
