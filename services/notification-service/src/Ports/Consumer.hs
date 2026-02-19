module Ports.Consumer
  ( module Service.Kafka,
    consumerConfig,
  )
where

import qualified Data.Aeson as Aeson
import Data.Aeson (Value)
import Domain.Notifications (Domain, NotificationMessage, processNotification)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.CorrelationId (logErrorC)
import Service.Kafka

notificationsTopic :: TopicName
notificationsTopic = TopicName "notifications"

-- | Build the Kafka consumer configuration.
-- The consumer loop automatically sends failing messages to the dead-letter
-- topic after 'maxRetries' attempts — handlers only need to throw on error.
consumerConfig ::
  Domain env =>
  Settings ->
  ConsumerConfig env
consumerConfig kafkaSettings =
  ConsumerConfig
    { brokerAddress = kafkaBroker kafkaSettings,
      groupId = kafkaGroupId kafkaSettings,
      topicHandlers =
        [ TopicHandler
            { topic = notificationsTopic,
              handler = notificationHandler
            }
        ],
      deadLetterTopic = TopicName (kafkaDeadLetterTopic kafkaSettings),
      maxRetries = kafkaMaxRetries kafkaSettings,
      consumerRecordMessageMetrics = \_ _ _ _ -> return (),
      consumerRecordOffsetMetrics = \_ _ _ _ -> return ()
    }

-- | Parse and dispatch a notification message.
-- Throws (→ dead letter) if the payload cannot be decoded as JSON.
notificationHandler ::
  Domain env =>
  Value ->
  RIO env ()
notificationHandler jsonValue =
  case Aeson.fromJSON @NotificationMessage jsonValue of
    Aeson.Error err -> do
      let msg = "Failed to parse notification message: " <> err
      logErrorC (fromString msg)
      throwString msg
    Aeson.Success msg -> processNotification msg
