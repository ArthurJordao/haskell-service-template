module Ports.Consumer
  ( module Service.Kafka,
    consumerConfig,
  )
where

import Kafka.Consumer (TopicName (..))
import RIO ()
import Service.Kafka

consumerConfig :: Settings -> ConsumerConfig env
consumerConfig kafkaSettings =
  ConsumerConfig
    { brokerAddress = kafkaBroker kafkaSettings,
      groupId = kafkaGroupId kafkaSettings,
      topicHandlers = [],
      deadLetterTopic = TopicName (kafkaDeadLetterTopic kafkaSettings),
      maxRetries = kafkaMaxRetries kafkaSettings
    }
