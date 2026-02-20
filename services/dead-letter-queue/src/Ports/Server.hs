module Ports.Server
  ( API,
    Routes (..),
    HasConfig (..),
    server,
    module Service.Server,
    module Types.Out.DLQ,
  )
where

import Database.Persist.Sql (Entity (..), fromSqlKey)
import qualified Domain.DeadLetters as Domain
import DB.DeadLetter (DeadLetter (..))
import RIO
import Servant
import Servant.Server.Generic (AsServerT)
import Service.Auth (HasScopes)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))
import Service.Server
import Types.Out.DLQ

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
          :> HasScopes '["admin"]
          :> QueryParam "status" Text
          :> QueryParam "topic" Text
          :> QueryParam "error_type" Text
          :> Get '[JSON] [DeadLetterResponse],
    getDeadLetter ::
      route
        :- Summary "Get a single dead letter message by ID"
          :> "dlq"
          :> HasScopes '["admin"]
          :> Capture "id" Int64
          :> Get '[JSON] DeadLetterResponse,
    replayMessage ::
      route
        :- Summary "Replay a single dead letter message to its original topic"
          :> "dlq"
          :> HasScopes '["admin"]
          :> Capture "id" Int64
          :> "replay"
          :> Post '[JSON] ReplayResult,
    replayBatch ::
      route
        :- Summary "Replay multiple dead letter messages"
          :> "dlq"
          :> HasScopes '["admin"]
          :> "replay-batch"
          :> ReqBody '[JSON] [Int64]
          :> Post '[JSON] [ReplayResult],
    discardMessage ::
      route
        :- Summary "Discard a dead letter message (mark as handled)"
          :> "dlq"
          :> HasScopes '["admin"]
          :> Capture "id" Int64
          :> "discard"
          :> Post '[JSON] NoContent,
    getStats ::
      route
        :- Summary "Get DLQ statistics"
          :> "dlq"
          :> HasScopes '["admin"]
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
    HasDB env,
    HasKafkaProducer env
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      listDeadLetters = \_claims -> listDeadLettersHandler,
      getDeadLetter = \_claims -> getDeadLetterHandler,
      replayMessage = \_claims -> Domain.replayMessage,
      replayBatch = \_claims -> Domain.replayBatch,
      discardMessage = \_claims -> discardMessageHandler,
      getStats = \_claims -> Domain.getStats
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
    { id = dlqId,
      originalTopic = deadLetterOriginalTopic dl,
      originalMessage = deadLetterOriginalMessage dl,
      originalHeaders = deadLetterOriginalHeaders dl,
      errorType = deadLetterErrorType dl,
      errorDetails = deadLetterErrorDetails dl,
      correlationId = deadLetterCorrelationId dl,
      createdAt = deadLetterCreatedAt dl,
      retryCount = deadLetterRetryCount dl,
      status = deadLetterStatus dl,
      replayedAt = deadLetterReplayedAt dl,
      replayedBy = deadLetterReplayedBy dl,
      replayResult = deadLetterReplayResult dl
    }
