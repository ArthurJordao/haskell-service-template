module Service.Metadata
  ( EntityMetadata (..),
    getMetadata,
    HasMeta (..),
  )
where

import Data.Time.Clock (UTCTime, getCurrentTime)
import RIO
import Service.CorrelationId (HasCorrelationId (..), unCorrelationId)

-- | Snapshot of audit metadata captured from the current request context.
data EntityMetadata = EntityMetadata
  { metaCreatedAt :: !UTCTime,
    metaCreatedByCid :: !Text
  }

-- | Types that carry metadata fields which can be overwritten atomically on insert.
class HasMeta a where
  applyMeta :: EntityMetadata -> a -> a

-- | Capture audit metadata from the current environment (timestamp + correlation ID).
getMetadata ::
  (HasCorrelationId env, MonadIO m, MonadReader env m) =>
  m EntityMetadata
getMetadata = do
  now <- liftIO getCurrentTime
  cid <- unCorrelationId <$> view correlationIdL
  return EntityMetadata {metaCreatedAt = now, metaCreatedByCid = cid}
