module Ports.Consumer
  ( module Service.Kafka,
    consumerConfig,
  )
where

import Data.Aeson (Value)
import Domain.DeadLetters (processDeadLetter)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.Database (HasDB (..))
import Service.CorrelationId (HasLogContext (..))
import Service.Kafka

consumerConfig ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env
  ) =>
  Settings ->
  ConsumerConfig env
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
      maxRetries = kafkaMaxRetries kafkaSettings,
      consumerRecordMessageMetrics = \_ _ _ _ -> return (),
      consumerRecordOffsetMetrics = \_ _ _ _ -> return ()
    }

deadLetterHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  Value ->
  RIO env ()
deadLetterHandler = processDeadLetter
