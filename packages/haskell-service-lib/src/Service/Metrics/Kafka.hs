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
import Service.Metrics.Optional

-- ============================================================================
-- Kafka Metrics Data Structure
-- ============================================================================

data KafkaMetrics = KafkaMetrics
  { kafkaMessagesConsumed :: !(Map Text Counter),
    -- Key: topic
    kafkaMessageDuration :: !(Map Text Histogram),
    -- Key: topic
    kafkaDLQMessages :: !(Map (Text, Text) Counter),
    -- Key: (topic, error_type)
    kafkaConsumerOffset :: !(Map (Text, Int) Gauge),
    -- Key: (topic, partition)
    kafkaHighWaterMark :: !(Map (Text, Int) Gauge),
    -- Key: (topic, partition)
    kafkaConsumerLag :: !(Map (Text, Int) Gauge)
    -- Key: (topic, partition)
  }

class HasKafkaMetrics env where
  kafkaMetricsL :: Lens' env KafkaMetrics

-- ============================================================================
-- Initialization
-- ============================================================================

initKafkaMetrics :: IO KafkaMetrics
initKafkaMetrics =
  return
    KafkaMetrics
      { kafkaMessagesConsumed = Map.empty,
        kafkaMessageDuration = Map.empty,
        kafkaDLQMessages = Map.empty,
        kafkaConsumerOffset = Map.empty,
        kafkaHighWaterMark = Map.empty,
        kafkaConsumerLag = Map.empty
      }

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

  -- Get or create counter for this topic
  counter <- liftIO $ atomically $ do
    case Map.lookup topicName (kafkaMessagesConsumed metrics) of
      Just c -> return c
      Nothing -> unsafeIOToSTM newCounter

  liftIO $ incCounter counter

  -- Run handler
  result <- tryAny (handler value)

  end <- liftIO getCurrentTime
  let duration = realToFrac $ diffUTCTime end start

  -- Get or create histogram for this topic
  histogram <- liftIO $ atomically $ do
    case Map.lookup topicName (kafkaMessageDuration metrics) of
      Just h -> return h
      Nothing -> unsafeIOToSTM $ newHistogram defaultBuckets

  liftIO $ observeHistogram histogram duration

  case result of
    Left ex -> do
      -- Record DLQ metric
      dlqCounter <- liftIO $ atomically $ do
        case Map.lookup (topicName, "handler_error") (kafkaDLQMessages metrics) of
          Just c -> return c
          Nothing -> unsafeIOToSTM newCounter
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

  -- Increment message counter
  counter <- liftIO $ atomically $ do
    case Map.lookup topicName (kafkaMessagesConsumed metrics) of
      Just c -> return c
      Nothing -> unsafeIOToSTM newCounter
  liftIO $ incCounter counter

  -- Record duration histogram
  histogram <- liftIO $ atomically $ do
    case Map.lookup topicName (kafkaMessageDuration metrics) of
      Just h -> return h
      Nothing -> unsafeIOToSTM $ newHistogram defaultBuckets
  liftIO $ observeHistogram histogram duration

  -- Record DLQ metrics on error
  case result of
    Left _ -> do
      dlqCounter <- liftIO $ atomically $ do
        case Map.lookup (topicName, "handler_error") (kafkaDLQMessages metrics) of
          Just c -> return c
          Nothing -> unsafeIOToSTM newCounter
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

  -- Update current offset
  offsetGauge <- liftIO $ atomically $ do
    case Map.lookup key (kafkaConsumerOffset metrics) of
      Just g -> return g
      Nothing -> unsafeIOToSTM newGauge
  liftIO $ setGauge offsetGauge (fromIntegral currentOffset)

  -- Update high water mark
  hwmGauge <- liftIO $ atomically $ do
    case Map.lookup key (kafkaHighWaterMark metrics) of
      Just g -> return g
      Nothing -> unsafeIOToSTM newGauge
  liftIO $ setGauge hwmGauge (fromIntegral highWaterMark)

  -- Update lag
  lagGauge <- liftIO $ atomically $ do
    case Map.lookup key (kafkaConsumerLag metrics) of
      Just g -> return g
      Nothing -> unsafeIOToSTM newGauge
  liftIO $ setGauge lagGauge (fromIntegral lag)

-- ============================================================================
-- Metrics Export
-- ============================================================================

exportKafkaMetrics :: KafkaMetrics -> IO [Text]
exportKafkaMetrics metrics = do
  consumedCounts <- forM (Map.toList $ kafkaMessagesConsumed metrics) $ \(topic, Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "kafka_messages_consumed_total{topic=\"" <> topic <> "\"} " <> T.pack (show count)

  dlqCounts <- forM (Map.toList $ kafkaDLQMessages metrics) $ \((topic, errorType), Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "kafka_dlq_messages_total{topic=\"" <> topic <> "\",error_type=\"" <> errorType <> "\"} " <> T.pack (show count)

  offsets <- forM (Map.toList $ kafkaConsumerOffset metrics) $ \((topic, partition), Gauge tvar) -> do
    offset <- readTVarIO tvar
    return $ "kafka_consumer_offset{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show offset)

  highWaterMarks <- forM (Map.toList $ kafkaHighWaterMark metrics) $ \((topic, partition), Gauge tvar) -> do
    hwm <- readTVarIO tvar
    return $ "kafka_high_water_mark{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show hwm)

  lags <- forM (Map.toList $ kafkaConsumerLag metrics) $ \((topic, partition), Gauge tvar) -> do
    lag <- readTVarIO tvar
    return $ "kafka_consumer_lag{topic=\"" <> topic <> "\",partition=\"" <> T.pack (show partition) <> "\"} " <> T.pack (show lag)

  return $
    ["# HELP kafka_messages_consumed_total Total Kafka messages consumed", "# TYPE kafka_messages_consumed_total counter"]
      <> consumedCounts
      <> ["# HELP kafka_dlq_messages_total Messages sent to dead letter queue", "# TYPE kafka_dlq_messages_total counter"]
      <> dlqCounts
      <> ["# HELP kafka_consumer_offset Current consumer offset per partition", "# TYPE kafka_consumer_offset gauge"]
      <> offsets
      <> ["# HELP kafka_high_water_mark Highest offset in the partition (latest message)", "# TYPE kafka_high_water_mark gauge"]
      <> highWaterMarks
      <> ["# HELP kafka_consumer_lag Lag between consumer offset and high water mark", "# TYPE kafka_consumer_lag gauge"]
      <> lags
