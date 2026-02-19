module Ports.Produce
  ( AccountCreatedEvent (..),
    publishAccountCreated,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.Kafka (HasKafkaProducer (..))

data AccountCreatedEvent = AccountCreatedEvent
  { eventAccountId :: !Int,
    eventAccountName :: !Text,
    eventAccountEmail :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

publishAccountCreated :: HasKafkaProducer env => Int64 -> Text -> Text -> RIO env ()
publishAccountCreated accountId name email =
  produceKafkaMessage
    (TopicName "account-created")
    Nothing
    AccountCreatedEvent
      { eventAccountId = fromIntegral accountId,
        eventAccountName = name,
        eventAccountEmail = email
      }
