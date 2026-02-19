module Ports.Consumer
  ( module Service.Kafka,
    consumerConfig,
  )
where

import Data.Aeson (Result (..), Value, fromJSON)
import Domain.Accounts (processUserRegistered)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.CorrelationId (HasLogContext (..), logInfoC, logWarnC)
import Service.Database (HasDB (..))
import Service.Events (UserRegisteredEvent (..))
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
            { topic = TopicName "account-created",
              handler = accountCreatedHandler
            },
          TopicHandler
            { topic = TopicName "user-registered",
              handler = userRegisteredHandler
            }
        ],
      deadLetterTopic = TopicName (kafkaDeadLetterTopic kafkaSettings),
      maxRetries = kafkaMaxRetries kafkaSettings,
      consumerRecordMessageMetrics = \_ _ _ _ -> return (),
      consumerRecordOffsetMetrics = \_ _ _ _ -> return ()
    }

accountCreatedHandler :: (HasLogFunc env, HasLogContext env) => Value -> RIO env ()
accountCreatedHandler jsonValue =
  logInfoC $ "Account created event received: " <> displayShow jsonValue

userRegisteredHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env
  ) =>
  Value ->
  RIO env ()
userRegisteredHandler jsonValue =
  case fromJSON @UserRegisteredEvent jsonValue of
    Error e -> logWarnC $ "Invalid user-registered payload: " <> displayShow e
    Success (UserRegisteredEvent uid email) ->
      processUserRegistered uid email
