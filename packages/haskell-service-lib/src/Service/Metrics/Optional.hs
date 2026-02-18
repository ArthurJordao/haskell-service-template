module Service.Metrics.Optional
  ( OptionalKafkaMetrics (..),
    OptionalDatabaseMetrics (..),
  )
where

import Data.Time.Clock (UTCTime)
import RIO

-- ============================================================================
-- Optional Metrics Type Classes
-- ============================================================================
-- These provide default "no-op" implementations when metrics aren't available

class OptionalKafkaMetrics env where
  recordKafkaMessageMetrics ::
    Text -> -- topic name
    UTCTime -> -- start time
    UTCTime -> -- end time
    Either SomeException a ->
    RIO env ()

  recordKafkaOffsetMetrics ::
    Text -> -- topic name
    Int -> -- partition
    Int -> -- current offset
    Int -> -- high water mark
    RIO env ()

  -- Default implementations do nothing
  recordKafkaMessageMetrics _ _ _ _ = return ()
  recordKafkaOffsetMetrics _ _ _ _ = return ()

class OptionalDatabaseMetrics env where
  recordDatabaseQueryMetrics ::
    Text -> -- operation type
    UTCTime -> -- start time
    UTCTime -> -- end time
    Either SomeException a ->
    RIO env ()

  -- Default implementation does nothing
  recordDatabaseQueryMetrics _ _ _ _ = return ()

-- Default instances are provided in Service.Metrics to avoid conflicts
