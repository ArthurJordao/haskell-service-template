module Ports.Kafka
  ( module Service.Kafka,
    consumerConfig,
    deadLetterHandler,
  )
where

import Data.Aeson (Value, FromJSON (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.Persist.Sql (insert)
import Kafka.Consumer (TopicName (..))
import Models.DeadLetter (DeadLetter (..))
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Service.CorrelationId (HasLogContext (..), logInfoC, logErrorC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Service.Kafka

-- | Incoming dead letter message from Kafka (matches the shared lib's DeadLetterMessage structure)
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

consumerConfig :: (HasLogFunc env, HasLogContext env, HasDB env) => Settings -> ConsumerConfig env
consumerConfig kafkaSettings =
  ConsumerConfig
    { brokerAddress = kafkaBroker kafkaSettings,
      groupId = kafkaGroupId kafkaSettings,
      topicHandlers =
        [ TopicHandler
            { topic = TopicName (kafkaDeadLetterTopic kafkaSettings),
              handler = deadLetterHandler
            }
        ],
      deadLetterTopic = TopicName "DEADLETTER-DLQ",
      maxRetries = kafkaMaxRetries kafkaSettings
    }

-- | Convert a JSON Value to Text for storage
valueToText :: Value -> Text
valueToText = TE.decodeUtf8 . BL.toStrict . Aeson.encode

deadLetterHandler :: (HasLogFunc env, HasLogContext env, HasDB env) => Value -> RIO env ()
deadLetterHandler jsonValue = do
  logInfoC "Received dead letter message"
  case Aeson.fromJSON jsonValue of
    Aeson.Error err -> do
      logErrorC $ "Failed to parse dead letter message: " <> displayShow err
      now <- liftIO getCurrentTime
      pool <- view dbL
      let dl = DeadLetter
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
      void $ runSqlPoolWithCid (insert dl) pool
    Aeson.Success incoming -> do
      pool <- view dbL
      let dl = DeadLetter
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
      dlId <- runSqlPoolWithCid (insert dl) pool
      logInfoC $ "Stored dead letter message with ID: " <> displayShow dlId
