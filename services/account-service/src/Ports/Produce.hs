{-# LANGUAGE NoOverloadedRecordDot #-}

module Ports.Produce
  ( AccountCreatedEvent (..),
    publishAccountCreated,
    publishWelcomeNotification,
  )
where

import Data.Aeson (FromJSON, ToJSON (..), object, (.=))
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

-- Local mirror of notification-service's types.
-- Field names and JSON encoding must stay in sync with notification-service.
data NotificationChannel
  = Email !Text
  deriving stock (Generic)

instance ToJSON NotificationChannel where
  toJSON (Email addr) = object ["channelType" .= ("email" :: Text), "channelAddress" .= addr]

data NotificationVariable = NotificationVariable
  { propertyName :: !Text,
    propertyValue :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

data NotificationMessage = NotificationMessage
  { notifTemplateName :: !Text,
    notifVariables :: ![NotificationVariable],
    notifChannel :: !NotificationChannel
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

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

publishWelcomeNotification :: HasKafkaProducer env => Text -> RIO env ()
publishWelcomeNotification email =
  produceKafkaMessage
    (TopicName "notifications")
    Nothing
    NotificationMessage
      { notifTemplateName = "welcome_email",
        notifVariables =
          [ NotificationVariable {propertyName = "name", propertyValue = email},
            NotificationVariable {propertyName = "email", propertyValue = email},
            NotificationVariable {propertyName = "actionUrl", propertyValue = "http://localhost:5173"}
          ],
        notifChannel = Email email
      }
