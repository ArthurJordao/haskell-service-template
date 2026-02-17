module Ports.Server
  ( API,
    Routes (..),
    DeadLetterResponse (..),
    ReplayResult (..),
    DLQStats (..),
    server,
    HasConfig (..),
    module Service.Server,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, decode, encode)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.Text.Encoding as TE
import Database.Persist.Sql (Entity (..), PersistStoreWrite (update), SelectOpt (..), entityVal, fromSqlKey, get, insert, selectList, toSqlKey, (==.), (=.))
import Kafka.Consumer (TopicName (..))
import Models.DeadLetter
import RIO
import qualified RIO.ByteString.Lazy as BL
import RIO.Text (pack)
import Servant
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), logInfoC, logErrorC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Service.Kafka (HasKafkaProducer (..))
import Service.Metrics.Optional (OptionalDatabaseMetrics)
import Service.Server

-- ============================================================================
-- API Types
-- ============================================================================

data DeadLetterResponse = DeadLetterResponse
  { dlrId :: !Int64,
    dlrOriginalTopic :: !Text,
    dlrOriginalMessage :: !Text,
    dlrOriginalHeaders :: !Text,
    dlrErrorType :: !Text,
    dlrErrorDetails :: !Text,
    dlrCorrelationId :: !Text,
    dlrCreatedAt :: !UTCTime,
    dlrRetryCount :: !Int,
    dlrStatus :: !Text,
    dlrReplayedAt :: !(Maybe UTCTime),
    dlrReplayedBy :: !(Maybe Text),
    dlrReplayResult :: !(Maybe Text)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ReplayResult = ReplayResult
  { replayId :: !Int64,
    replaySuccess :: !Bool,
    replayError :: !(Maybe Text)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data DLQStats = DLQStats
  { totalMessages :: !Int,
    pendingMessages :: !Int,
    replayedMessages :: !Int,
    discardedMessages :: !Int,
    byErrorType :: !(Map Text Int)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Routes route = Routes
  { status ::
      route
        :- Summary "Health check endpoint"
          :> "status"
          :> Get '[JSON] Text,
    listDeadLetters ::
      route
        :- Summary "List dead letter messages with optional filters"
          :> "dlq"
          :> QueryParam "status" Text
          :> QueryParam "topic" Text
          :> QueryParam "error_type" Text
          :> Get '[JSON] [DeadLetterResponse],
    getDeadLetter ::
      route
        :- Summary "Get a single dead letter message by ID"
          :> "dlq"
          :> Capture "id" Int64
          :> Get '[JSON] DeadLetterResponse,
    replayMessage ::
      route
        :- Summary "Replay a single dead letter message to its original topic"
          :> "dlq"
          :> Capture "id" Int64
          :> "replay"
          :> Post '[JSON] ReplayResult,
    replayBatch ::
      route
        :- Summary "Replay multiple dead letter messages"
          :> "dlq"
          :> "replay-batch"
          :> ReqBody '[JSON] [Int64]
          :> Post '[JSON] [ReplayResult],
    discardMessage ::
      route
        :- Summary "Discard a dead letter message (mark as handled)"
          :> "dlq"
          :> Capture "id" Int64
          :> "discard"
          :> Post '[JSON] NoContent,
    getStats ::
      route
        :- Summary "Get DLQ statistics"
          :> "dlq"
          :> "stats"
          :> Get '[JSON] DLQStats
  }
  deriving stock (Generic)

type API = NamedRoutes Routes

-- ============================================================================
-- Server Implementation
-- ============================================================================

server :: (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasConfig env settings, HasDB env, HasKafkaProducer env, OptionalDatabaseMetrics env) => Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      listDeadLetters = listDeadLettersHandler,
      getDeadLetter = getDeadLetterHandler,
      replayMessage = replayMessageHandler,
      replayBatch = replayBatchHandler,
      discardMessage = discardMessageHandler,
      getStats = getStatsHandler
    }

statusHandler :: forall env settings. (HasLogFunc env, HasLogContext env, HasConfig env settings) => RIO env Text
statusHandler = do
  logInfoC "DLQ status endpoint called"
  return "OK"

listDeadLettersHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) =>
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  RIO env [DeadLetterResponse]
listDeadLettersHandler maybeStatus maybeTopic maybeErrorType = do
  logInfoC "Listing dead letter messages"
  pool <- view dbL
  let filters =
        catMaybes
          [ (DeadLetterStatus ==.) <$> maybeStatus,
            (DeadLetterOriginalTopic ==.) <$> maybeTopic,
            (DeadLetterErrorType ==.) <$> maybeErrorType
          ]
  entities <- runSqlPoolWithCid (selectList filters [Desc DeadLetterCreatedAt]) pool
  return $ map entityToResponse entities

getDeadLetterHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) =>
  Int64 ->
  RIO env DeadLetterResponse
getDeadLetterHandler dlqId = do
  logInfoC $ "Getting dead letter message with ID: " <> displayShow dlqId
  pool <- view dbL
  maybeDl <- runSqlPoolWithCid (get (toSqlKey dlqId :: DeadLetterId)) pool
  case maybeDl of
    Just dl -> return $ toResponse dlqId dl
    Nothing -> throwM err404 {errBody = "Dead letter message not found"}

replayMessageHandler ::
  (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasDB env, HasKafkaProducer env, OptionalDatabaseMetrics env) =>
  Int64 ->
  RIO env ReplayResult
replayMessageHandler dlqId = do
  logInfoC $ "Replaying dead letter message: " <> displayShow dlqId
  pool <- view dbL
  let key = toSqlKey dlqId :: DeadLetterId
  maybeDl <- runSqlPoolWithCid (get key) pool
  case maybeDl of
    Nothing -> return $ ReplayResult dlqId False (Just "Not found")
    Just dl -> do
      let msgBytes = BL.fromStrict $ TE.encodeUtf8 (deadLetterOriginalMessage dl)
      case decode msgBytes :: Maybe Value of
        Nothing -> do
          let errMsg :: Text
              errMsg = "Failed to parse original message as JSON"
          logErrorC $ display errMsg
          now <- liftIO getCurrentTime
          runSqlPoolWithCid
            ( update key
                [ DeadLetterReplayResult =. Just errMsg,
                  DeadLetterReplayedAt =. Just now
                ]
            )
            pool
          return $ ReplayResult dlqId False (Just errMsg)
        Just jsonVal -> do
          let originalCid = CorrelationId (deadLetterCorrelationId dl)
          result <- tryAny $
            local (set correlationIdL originalCid) $
              produceKafkaMessage (TopicName $ deadLetterOriginalTopic dl) Nothing jsonVal
          now <- liftIO getCurrentTime
          case result of
            Left ex -> do
              let errMsg = "Replay failed: " <> pack (show ex)
              runSqlPoolWithCid
                ( update key
                    [ DeadLetterReplayResult =. Just errMsg,
                      DeadLetterReplayedAt =. Just now
                    ]
                )
                pool
              return $ ReplayResult dlqId False (Just errMsg)
            Right _ -> do
              runSqlPoolWithCid
                ( update key
                    [ DeadLetterStatus =. "replayed",
                      DeadLetterReplayedAt =. Just now,
                      DeadLetterReplayResult =. Just "success"
                    ]
                )
                pool
              logInfoC $ "Successfully replayed message " <> displayShow dlqId <> " with original cid: " <> display (deadLetterCorrelationId dl)
              return $ ReplayResult dlqId True Nothing

replayBatchHandler ::
  (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasDB env, HasKafkaProducer env, OptionalDatabaseMetrics env) =>
  [Int64] ->
  RIO env [ReplayResult]
replayBatchHandler ids = do
  logInfoC $ "Replaying batch of " <> displayShow (length ids) <> " messages"
  mapM replayMessageHandler ids

discardMessageHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) =>
  Int64 ->
  RIO env NoContent
discardMessageHandler dlqId = do
  logInfoC $ "Discarding dead letter message: " <> displayShow dlqId
  pool <- view dbL
  let key = toSqlKey dlqId :: DeadLetterId
  maybeDl <- runSqlPoolWithCid (get key) pool
  case maybeDl of
    Nothing -> throwM err404 {errBody = "Dead letter message not found"}
    Just _ -> do
      now <- liftIO getCurrentTime
      runSqlPoolWithCid
        ( update key
            [ DeadLetterStatus =. "discarded",
              DeadLetterReplayedAt =. Just now
            ]
        )
        pool
      return NoContent

getStatsHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) =>
  RIO env DLQStats
getStatsHandler = do
  logInfoC "Getting DLQ statistics"
  pool <- view dbL
  allMessages <- runSqlPoolWithCid (selectList [] []) pool
  let entities = map entityVal allMessages
      total = length entities
      pending = length $ filter (\dl -> deadLetterStatus dl == "pending") entities
      replayed = length $ filter (\dl -> deadLetterStatus dl == "replayed") entities
      discarded = length $ filter (\dl -> deadLetterStatus dl == "discarded") entities
      errorTypes = foldl' (\acc dl -> Map.insertWith (+) (deadLetterErrorType dl) 1 acc) Map.empty entities
  return
    DLQStats
      { totalMessages = total,
        pendingMessages = pending,
        replayedMessages = replayed,
        discardedMessages = discarded,
        byErrorType = errorTypes
      }

-- ============================================================================
-- Helpers
-- ============================================================================

entityToResponse :: Entity DeadLetter -> DeadLetterResponse
entityToResponse (Entity key dl) = toResponse (fromSqlKey key) dl

toResponse :: Int64 -> DeadLetter -> DeadLetterResponse
toResponse dlqId dl =
  DeadLetterResponse
    { dlrId = dlqId,
      dlrOriginalTopic = deadLetterOriginalTopic dl,
      dlrOriginalMessage = deadLetterOriginalMessage dl,
      dlrOriginalHeaders = deadLetterOriginalHeaders dl,
      dlrErrorType = deadLetterErrorType dl,
      dlrErrorDetails = deadLetterErrorDetails dl,
      dlrCorrelationId = deadLetterCorrelationId dl,
      dlrCreatedAt = deadLetterCreatedAt dl,
      dlrRetryCount = deadLetterRetryCount dl,
      dlrStatus = deadLetterStatus dl,
      dlrReplayedAt = deadLetterReplayedAt dl,
      dlrReplayedBy = deadLetterReplayedBy dl,
      dlrReplayResult = deadLetterReplayResult dl
    }

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  httpSettings :: settings -> Settings
