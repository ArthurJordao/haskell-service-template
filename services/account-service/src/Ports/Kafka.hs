module Ports.Kafka
  ( module Service.Kafka,
    consumerConfig,
    testTopicHandler,
  )
where

import Data.Aeson (Value)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Kafka

consumerConfig :: (HasLogFunc env, HasLogContext env) => Settings -> ConsumerConfig env
consumerConfig kafkaSettings =
  ConsumerConfig
    { brokerAddress = kafkaBroker kafkaSettings,
      groupId = kafkaGroupId kafkaSettings,
      topicHandlers =
        [ TopicHandler
            { topic = TopicName "test-topic",
              handler = testTopicHandler
            },
          TopicHandler
            { topic = TopicName "account-created",
              handler = accountCreatedHandler
            }
        ],
      deadLetterTopic = TopicName (kafkaDeadLetterTopic kafkaSettings),
      maxRetries = kafkaMaxRetries kafkaSettings
    }

testTopicHandler :: (HasLogFunc env, HasLogContext env) => Value -> RIO env ()
testTopicHandler jsonValue = do
  logInfoC $ "Processing message from test-topic: " <> displayShow jsonValue

accountCreatedHandler :: (HasLogFunc env, HasLogContext env) => Value -> RIO env ()
accountCreatedHandler jsonValue = do
  logInfoC $ "Account created event received: " <> displayShow jsonValue
