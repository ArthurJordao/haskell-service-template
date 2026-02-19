module Ports.Kafka
  ( module Service.Kafka,
    consumerConfig,
    testTopicHandler,
  )
where

import Data.Aeson (Result (..), Value, fromJSON)
import Database.Persist.Sql (get, insertKey, toSqlKey)
import Kafka.Consumer (TopicName (..))
import Models.Account (Account (..), AccountId)
import RIO
import Service.CorrelationId (HasLogContext (..), logInfoC, logWarnC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Service.Events (UserRegisteredEvent (..))
import Service.Kafka
import Service.Metrics.Optional (OptionalDatabaseMetrics)

consumerConfig ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    OptionalDatabaseMetrics env
  ) =>
  Settings ->
  ConsumerConfig env
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
            },
          TopicHandler
            { topic = TopicName "user-registered",
              handler = userRegisteredHandler
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

userRegisteredHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    OptionalDatabaseMetrics env
  ) =>
  Value ->
  RIO env ()
userRegisteredHandler jsonValue =
  case fromJSON @UserRegisteredEvent jsonValue of
    Error e -> logWarnC $ "Invalid user-registered payload: " <> displayShow e
    Success (UserRegisteredEvent uid email) -> do
      pool <- view dbL
      let key = toSqlKey uid :: AccountId
      existing <- runSqlPoolWithCid (get key) pool
      case existing of
        Just _ -> logInfoC $ "Account already exists for user " <> displayShow uid
        Nothing -> do
          runSqlPoolWithCid (insertKey key Account {accountName = email, accountEmail = email}) pool
          logInfoC $ "Created account for user " <> displayShow uid
