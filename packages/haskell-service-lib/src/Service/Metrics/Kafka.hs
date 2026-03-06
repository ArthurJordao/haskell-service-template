module Service.Metrics.Kafka
  ( KafkaMetrics (..),
    HasKafkaMetrics (..),
    initKafkaMetrics,
    instrumentKafkaHandler,
    exportKafkaMetrics,
    recordKafkaMetricsInternal,
    recordKafkaOffsetMetricsInternal,
  )
where

import Data.Aeson (Value)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import qualified Data.Text as T
import GHC.Conc (unsafeIOToSTM)
import RIO
import Service.Metrics.Core

-- ============================================================================
-- Kafka Metrics Data Structure
-- ============================================================================

data KafkaMetrics = KafkaMetrics
  { kafkaMessagesConsumed :: TVar (Map Text Counter),
    -- Key: topic
    kafkaMessageDuration :: TVar (Map Text Histogram),
    -- Key: topic
    kafkaDLQMessages :: TVar (Map (Text, Text) Counter),
    -- Key: (topic, error_type)
    kafkaConsumerOffset :: TVar (Map (Text, Int) Gauge),
    -- Key: (topic, partition)
    kafkaHighWaterMark :: TVar (Map (Text, Int) Gauge),
    -- Key: (topic, partition)
    kafkaConsumerLag :: TVar (Map (Text, Int) Gauge)
    -- Key: (topic, partition)
  }

class HasKafkaMetrics env where
  kafkaMetricsL :: Lens' env KafkaMetrics

-- ============================================================================
-- Initialization
-- ============================================================================

initKafkaMetrics :: IO KafkaMetrics
initKafkaMetrics =
  KafkaMetrics
    <$> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty

-- ============================================================================
-- Kafka Instrumentation
-- ============================================================================

instrumentKafkaHandler ::
  (HasKafkaMetrics env, HasLogFunc env) =>
  Text ->
  (Value -> RIO env ()) ->
  (Value -> RIO env ())
instrumentKafkaHandler topicName handler = \value -> do
  metrics <- view kafkaMetricsL
  start <- liftIO getCurrentTime

  counter <- liftIO $ atomically $ do
    m <- readTVar (kafkaMessagesConsumed metrics)
    case Map.lookup topicName m of
      Just c -> return c
      Nothing -> do
        c <- unsafeIOToSTM newCounter
        modifyTVar' (kafkaMessagesConsumed metrics) (Map.insert topicName c)
        return c
  liftIO $ incCounter counter

  result <- tryAny (handler value)

  end <- liftIO getCurrentTime
  let duration = realToFrac $ diffUTCTime end start

  histogram <- liftIO $ atomically $ do
    m <- readTVar (kafkaMessageDuration metrics)
    case Map.lookup topicName m of
      Just h -> return h
      Nothing -> do
        h <- unsafeIOToSTM $ newHistogram defaultBuckets
        modifyTVar' (kafkaMessageDuration metrics) (Map.insert topicName h)
        return h
  liftIO $ observeHistogram histogram duration

  case result of
    Left ex -> do
      dlqCounter <- liftIO $ atomically $ do
        m <- readTVar (kafkaDLQMessages metrics)
        case Map.lookup (topicName, "handler_error") m of
          Just c -> return c
          Nothing -> do
            c <- unsafeIOToSTM newCounter
            modifyTVar' (kafkaDLQMessages metrics) (Map.insert (topicName, "handler_error") c)
            return c
      liftIO $ incCounter dlqCounter
      throwIO ex
    Right _ -> return ()

-- Overlapping instance is defined in Service.Metrics to avoid conflicts

-- ============================================================================
-- Internal Helper for Metrics Recording
-- ============================================================================

recordKafkaMetricsInternal ::
  (HasKafkaMetrics env, HasLogFunc env) =>
  Text ->
  UTCTime ->
  UTCTime ->
  Either SomeException a ->
  RIO env ()
recordKafkaMetricsInternal topicName start end result = do
  metrics <- view kafkaMetricsL
  let duration = realToFrac $ diffUTCTime end start

  counter <- liftIO $ atomically $ do
    m <- readTVar (kafkaMessagesConsumed metrics)
    case Map.lookup topicName m of
      Just c -> return c
      Nothing -> do
        c <- unsafeIOToSTM newCounter
        modifyTVar' (kafkaMessagesConsumed metrics) (Map.insert topicName c)
        return c
  liftIO $ incCounter counter

  histogram <- liftIO $ atomically $ do
    m <- readTVar (kafkaMessageDuration metrics)
    case Map.lookup topicName m of
      Just h -> return h
      Nothing -> do
        h <- unsafeIOToSTM $ newHistogram defaultBuckets
        modifyTVar' (kafkaMessageDuration metrics) (Map.insert topicName h)
        return h
  liftIO $ observeHistogram histogram duration

  case result of
    Left _ -> do
      dlqCounter <- liftIO $ atomically $ do
        m <- readTVar (kafkaDLQMessages metrics)
        case Map.lookup (topicName, "handler_error") m of
          Just c -> return c
          Nothing -> do
            c <- unsafeIOToSTM newCounter
            modifyTVar' (kafkaDLQMessages metrics) (Map.insert (topicName, "handler_error") c)
            return c
      liftIO $ incCounter dlqCounter
    Right _ -> return ()

recordKafkaOffsetMetricsInternal ::
  (HasKafkaMetrics env, HasLogFunc env) =>
  Text ->
  Int ->
  Int ->
  Int ->
  RIO env ()
recordKafkaOffsetMetricsInternal topicName partition currentOffset highWaterMark = do
  metrics <- view kafkaMetricsL
  let lag = highWaterMark - currentOffset
      key = (topicName, partition)

  offsetGauge <- liftIO $ atomically $ do
    m <- readTVar (kafkaConsumerOffset metrics)
    case Map.lookup key m of
      Just g -> return g
      Nothing -> do
        g <- unsafeIOToSTM newGauge
        modifyTVar' (kafkaConsumerOffset metrics) (Map.insert key g)
        return g
  liftIO $ setGauge offsetGauge (fromIntegral currentOffset)

  hwmGauge <- liftIO $ atomically $ do
    m <- readTVar (kafkaHighWaterMark metrics)
    case Map.lookup key m of
      Just g -> return g
      Nothing -> do
        g <- unsafeIOToSTM newGauge
        modifyTVar' (kafkaHighWaterMark metrics) (Map.insert key g)
        return g
  liftIO $ setGauge hwmGauge (fromIntegral highWaterMark)

  lagGauge <- liftIO $ atomically $ do
    m <- readTVar (kafkaConsumerLag metrics)
    case Map.lookup key m of
      Just g -> return g
      Nothing -> do
        g <- unsafeIOToSTM newGauge
        modifyTVar' (kafkaConsumerLag metrics) (Map.insert key g)
        return g
  liftIO $ setGauge lagGauge (fromIntegral lag)

-- ============================================================================
-- Metrics Export
-- ============================================================================

exportKafkaMetrics :: KafkaMetrics -> IO [Text]
exportKafkaMetrics metrics = do
  consumed    <- readTVarIO (kafkaMessagesConsumed metrics)
  dlq         <- readTVarIO (kafkaDLQMessages metrics)
  offsets     <- readTVarIO (kafkaConsumerOffset metrics)
  hwms        <- readTVarIO (kafkaHighWaterMark metrics)
  lags        <- readTVarIO (kafkaConsumerLag metrics)

  consumedCounts <- forM (Map.toList consumed) $ \(topic, Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "kafka_messages_consumed_total{topic=\"" <> topic <> "\"} " <> T.pack (show count)

  dlqCounts <- forM (Map.toList dlq) $ \((topic, errorType), Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "kafka_dlq_messages_total{topic=\"" <> topic <> "\",error_type=\"" <> errorType <> "\"} " <> T.pack (show count)

  offsetLines <- forM (Map.toList offsets) $ \((topic, partition), Gauge tvar) -> do
    offset <- readTVarIO tvar
    return $ "kafka_consumer_offset{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show offset)

  highWaterMarks <- forM (Map.toList hwms) $ \((topic, partition), Gauge tvar) -> do
    hwm <- readTVarIO tvar
    return $ "kafka_high_water_mark{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show hwm)

  lagLines <- forM (Map.toList lags) $ \((topic, partition), Gauge tvar) -> do
    lag <- readTVarIO tvar
    return $ "kafka_consumer_lag{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show lag)

  return $
    ["# HELP kafka_messages_consumed_total Total Kafka messages consumed", "# TYPE kafka_messages_consumed_total counter"]
      <> consumedCounts
      <> ["# HELP kafka_dlq_messages_total Messages sent to dead letter queue", "# TYPE kafka_dlq_messages_total counter"]
      <> dlqCounts
      <> ["# HELP kafka_consumer_offset Current consumer offset per partition", "# TYPE kafka_consumer_offset gauge"]
      <> offsetLines
      <> ["# HELP kafka_high_water_mark Highest offset in the partition (latest message)", "# TYPE kafka_high_water_mark gauge"]
      <> highWaterMarks
      <> ["# HELP kafka_consumer_lag Lag between consumer offset and high water mark", "# TYPE kafka_consumer_lag gauge"]
      <> lagLines
