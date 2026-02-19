module Ports.Produce
  ( publishUserRegistered,
  )
where

import Kafka.Consumer (TopicName (..))
import RIO
import Service.Events (UserRegisteredEvent (..))
import Service.Kafka (HasKafkaProducer (..))

publishUserRegistered :: HasKafkaProducer env => Int64 -> Text -> RIO env ()
publishUserRegistered uid email =
  produceKafkaMessage (TopicName "user-registered") Nothing
    (UserRegisteredEvent uid email)
