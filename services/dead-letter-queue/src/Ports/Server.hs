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

import Data.Aeson (FromJSON, ToJSON)
import Data.Time.Clock (UTCTime)
import Database.Persist.Sql (Entity (..), fromSqlKey)
import Domain.DeadLetters (DLQStats (..), ReplayResult (..))
import qualified Domain.DeadLetters as Domain
import Models.DeadLetter (DeadLetter (..))
import RIO
import Servant
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))
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

-- ============================================================================
-- Routes
-- ============================================================================

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
-- HasConfig
-- ============================================================================

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  httpSettings :: settings -> Settings

-- ============================================================================
-- Server (thin adapter — delegates to Domain)
-- ============================================================================

server ::
  ( HasLogFunc env,
    HasLogContext env,
    HasCorrelationId env,
    HasConfig env settings,
    HasDB env,
    HasKafkaProducer env
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      listDeadLetters = listDeadLettersHandler,
      getDeadLetter = getDeadLetterHandler,
      replayMessage = Domain.replayMessage,
      replayBatch = Domain.replayBatch,
      discardMessage = discardMessageHandler,
      getStats = Domain.getStats
    }

statusHandler ::
  (HasLogFunc env, HasLogContext env) =>
  RIO env Text
statusHandler = do
  logInfoC "DLQ status endpoint called"
  return "OK"

listDeadLettersHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  RIO env [DeadLetterResponse]
listDeadLettersHandler maybeStatus maybeTopic maybeErrorType = do
  entities <- Domain.listDeadLetters maybeStatus maybeTopic maybeErrorType
  return $ map entityToResponse entities

getDeadLetterHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  Int64 ->
  RIO env DeadLetterResponse
getDeadLetterHandler dlqId = do
  dl <- Domain.getDeadLetterById dlqId
  return $ toResponse dlqId dl

discardMessageHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  Int64 ->
  RIO env NoContent
discardMessageHandler dlqId = do
  Domain.discardMessage dlqId
  return NoContent

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
