module Service.Metrics
  ( -- * Core Types
    module Service.Metrics.Core,

    -- * HTTP Metrics
    module Service.Metrics.Http,

    -- * Kafka Metrics
    module Service.Metrics.Kafka,

    -- * Database Metrics
    module Service.Metrics.Database,

    -- * Optional Metrics
    module Service.Metrics.Optional,

    -- * Combined Metrics
    Metrics (..),
    HasMetrics (..),
    initMetrics,
    metricsHandler,
  )
where

import qualified Data.Text as T
import RIO
import Service.Metrics.Core
import Service.Metrics.Database
import Service.Metrics.Http
import Service.Metrics.Kafka (KafkaMetrics (..), HasKafkaMetrics (..), initKafkaMetrics, exportKafkaMetrics, instrumentKafkaHandler, recordKafkaMetricsInternal, recordKafkaOffsetMetricsInternal)
import Service.Metrics.Optional

-- ============================================================================
-- Combined Metrics Container
-- ============================================================================

data Metrics = Metrics
  { metricsHttp :: !HttpMetrics,
    metricsKafka :: !KafkaMetrics,
    metricsDatabase :: !DatabaseMetrics
  }

class HasMetrics env where
  metricsL :: Lens' env Metrics

-- Provide default instances that delegate to the combined container
instance HasMetrics env => HasHttpMetrics env where
  httpMetricsL = metricsL . lens metricsHttp (\m h -> m {metricsHttp = h})

instance HasMetrics env => HasKafkaMetrics env where
  kafkaMetricsL = metricsL . lens metricsKafka (\m k -> m {metricsKafka = k})

instance HasMetrics env => HasDatabaseMetrics env where
  databaseMetricsL = metricsL . lens metricsDatabase (\m d -> m {metricsDatabase = d})

-- ============================================================================
-- Initialization
-- ============================================================================

initMetrics :: IO Metrics
initMetrics = do
  httpMetrics <- initHttpMetrics
  kafkaMetrics <- initKafkaMetrics
  dbMetrics <- initDatabaseMetrics

  return
    Metrics
      { metricsHttp = httpMetrics,
        metricsKafka = kafkaMetrics,
        metricsDatabase = dbMetrics
      }

-- ============================================================================
-- Combined Metrics Handler
-- ============================================================================

metricsHandler :: Metrics -> IO Text
metricsHandler metrics = do
  -- Export all metrics in Prometheus text format
  metricLines <-
    sequence
      [ exportHttpMetrics (metricsHttp metrics),
        exportKafkaMetrics (metricsKafka metrics),
        exportDatabaseMetrics (metricsDatabase metrics)
      ]

  return $ T.intercalate "\n" $ concat metricLines

-- ============================================================================
-- Optional Metrics Instances
-- ============================================================================

-- Real instance when metrics are available
-- The default no-op implementations are provided by the type class itself
instance {-# OVERLAPPING #-} (HasKafkaMetrics env, HasLogFunc env) => OptionalKafkaMetrics env where
  recordKafkaMessageMetrics = recordKafkaMetricsInternal
  recordKafkaOffsetMetrics = recordKafkaOffsetMetricsInternal

instance {-# OVERLAPPING #-} (HasDatabaseMetrics env, HasLogFunc env) => OptionalDatabaseMetrics env where
  recordDatabaseQueryMetrics = recordDatabaseMetricsInternal
