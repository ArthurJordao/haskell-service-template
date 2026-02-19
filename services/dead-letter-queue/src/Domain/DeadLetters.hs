{-# LANGUAGE ConstraintKinds #-}

module Domain.DeadLetters
  ( Domain,
    ReplayResult (..),
    DLQStats (..),
    processDeadLetter,
    listDeadLetters,
    getDeadLetterById,
    replayMessage,
    replayBatch,
    discardMessage,
    getStats,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.Persist.Sql (Entity (..), toSqlKey)
import Kafka.Consumer (TopicName (..))
import Models.DeadLetter (DeadLetter (..), DeadLetterId)
import qualified Ports.Repository as Repo
import qualified RIO.ByteString.Lazy as BL
import RIO
import RIO.Text (pack)
import Servant (err404, errBody)
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), logErrorC, logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))

-- | Constraint alias for domain functions that need DB access.
type Domain env = (HasLogFunc env, HasLogContext env, HasDB env)

-- ============================================================================
-- Domain types
-- ============================================================================

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

-- ============================================================================
-- Incoming message type (Kafka payload format)
-- ============================================================================

data IncomingDeadLetter = IncomingDeadLetter
  { inOriginalTopic :: !Text,
    inOriginalMessage :: !Value,
    inOriginalHeaders :: ![(Text, Text)],
    inErrorType :: !Text,
    inErrorDetails :: !Text,
    inCorrelationId :: !Text,
    inTimestamp :: !UTCTime,
    inRetryCount :: !Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON IncomingDeadLetter where
  parseJSON = Aeson.withObject "IncomingDeadLetter" $ \o ->
    IncomingDeadLetter
      <$> o Aeson..: "originalTopic"
      <*> o Aeson..: "originalMessage"
      <*> o Aeson..: "originalHeaders"
      <*> o Aeson..: "errorType"
      <*> o Aeson..: "errorDetails"
      <*> o Aeson..: "correlationId"
      <*> o Aeson..: "timestamp"
      <*> o Aeson..: "retryCount"

-- ============================================================================
-- Domain functions
-- ============================================================================

-- | Parse and store an incoming dead letter Kafka message.
processDeadLetter :: Domain env => Value -> RIO env ()
processDeadLetter jsonValue = do
  logInfoC "Received dead letter message"
  case Aeson.fromJSON jsonValue of
    Aeson.Error err -> do
      logErrorC $ "Failed to parse dead letter message: " <> displayShow err
      now <- liftIO getCurrentTime
      let dl =
            DeadLetter
              { deadLetterOriginalTopic = "unknown",
                deadLetterOriginalMessage = valueToText jsonValue,
                deadLetterOriginalHeaders = "[]",
                deadLetterErrorType = "DLQ_PARSE_ERROR",
                deadLetterErrorDetails = fromString err,
                deadLetterCorrelationId = "",
                deadLetterCreatedAt = now,
                deadLetterRetryCount = 0,
                deadLetterStatus = "pending",
                deadLetterReplayedAt = Nothing,
                deadLetterReplayedBy = Nothing,
                deadLetterReplayResult = Nothing
              }
      void $ Repo.storeDeadLetter dl
    Aeson.Success incoming -> do
      let dl =
            DeadLetter
              { deadLetterOriginalTopic = inOriginalTopic incoming,
                deadLetterOriginalMessage = valueToText (inOriginalMessage incoming),
                deadLetterOriginalHeaders = valueToText (Aeson.toJSON $ inOriginalHeaders incoming),
                deadLetterErrorType = inErrorType incoming,
                deadLetterErrorDetails = inErrorDetails incoming,
                deadLetterCorrelationId = inCorrelationId incoming,
                deadLetterCreatedAt = inTimestamp incoming,
                deadLetterRetryCount = inRetryCount incoming,
                deadLetterStatus = "pending",
                deadLetterReplayedAt = Nothing,
                deadLetterReplayedBy = Nothing,
                deadLetterReplayResult = Nothing
              }
      dlId <- Repo.storeDeadLetter dl
      logInfoC $ "Stored dead letter message with ID: " <> displayShow dlId

-- | List dead letters with optional filters.
listDeadLetters ::
  Domain env =>
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  RIO env [Entity DeadLetter]
listDeadLetters maybeStatus maybeTopic maybeErrorType = do
  logInfoC "Listing dead letter messages"
  Repo.findDeadLetters maybeStatus maybeTopic maybeErrorType

-- | Get a dead letter by ID; throws 404 if not found.
getDeadLetterById :: Domain env => Int64 -> RIO env DeadLetter
getDeadLetterById dlqId = do
  logInfoC $ "Getting dead letter message with ID: " <> displayShow dlqId
  mDl <- Repo.findById dlqId
  case mDl of
    Nothing -> throwM err404 {errBody = "Dead letter message not found"}
    Just dl -> return dl

-- | Replay a dead letter message to its original Kafka topic.
replayMessage ::
  (Domain env, HasKafkaProducer env, HasCorrelationId env) =>
  Int64 ->
  RIO env ReplayResult
replayMessage dlqId = do
  logInfoC $ "Replaying dead letter message: " <> displayShow dlqId
  let key = toSqlKey dlqId :: DeadLetterId
  mDl <- Repo.findById dlqId
  case mDl of
    Nothing -> return $ ReplayResult dlqId False (Just "Not found")
    Just dl -> do
      let msgBytes = BL.fromStrict $ TE.encodeUtf8 (deadLetterOriginalMessage dl)
      case Aeson.decode msgBytes :: Maybe Value of
        Nothing -> do
          let errMsg :: Text
              errMsg = "Failed to parse original message as JSON"
          logErrorC $ display errMsg
          now <- liftIO getCurrentTime
          Repo.markReplayFailed key errMsg now
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
              Repo.markReplayFailed key errMsg now
              return $ ReplayResult dlqId False (Just errMsg)
            Right _ -> do
              Repo.markReplayed key now
              logInfoC $
                "Successfully replayed message "
                  <> displayShow dlqId
                  <> " with original cid: "
                  <> display (deadLetterCorrelationId dl)
              return $ ReplayResult dlqId True Nothing

-- | Replay multiple dead letter messages.
replayBatch ::
  (Domain env, HasKafkaProducer env, HasCorrelationId env) =>
  [Int64] ->
  RIO env [ReplayResult]
replayBatch ids = do
  logInfoC $ "Replaying batch of " <> displayShow (length ids) <> " messages"
  mapM replayMessage ids

-- | Mark a dead letter as discarded; throws 404 if not found.
discardMessage :: Domain env => Int64 -> RIO env ()
discardMessage dlqId = do
  logInfoC $ "Discarding dead letter message: " <> displayShow dlqId
  let key = toSqlKey dlqId :: DeadLetterId
  mDl <- Repo.findById dlqId
  case mDl of
    Nothing -> throwM err404 {errBody = "Dead letter message not found"}
    Just _ -> do
      now <- liftIO getCurrentTime
      Repo.markDiscarded key now

-- | Compute aggregate statistics over all dead letters.
getStats :: Domain env => RIO env DLQStats
getStats = do
  logInfoC "Getting DLQ statistics"
  entities <- Repo.findAll
  let total = length entities
      pending = length $ filter (\dl -> deadLetterStatus dl == "pending") entities
      replayed = length $ filter (\dl -> deadLetterStatus dl == "replayed") entities
      discarded = length $ filter (\dl -> deadLetterStatus dl == "discarded") entities
      errorTypes =
        foldl'
          (\acc dl -> Map.insertWith (+) (deadLetterErrorType dl) 1 acc)
          Map.empty
          entities
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

valueToText :: Value -> Text
valueToText = TE.decodeUtf8 . BL.toStrict . Aeson.encode
