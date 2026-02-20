module Ports.Produce
  ( publishAccountCreated,
    publishWelcomeNotification,
  )
where

import Kafka.Consumer (TopicName (..))
import RIO
import Service.Kafka (HasKafkaProducer (..))
import Types.Out.AccountCreated (AccountCreatedEvent (..))
import Types.Out.Notifications

publishAccountCreated :: HasKafkaProducer env => Int64 -> Text -> Text -> RIO env ()
publishAccountCreated acctId name email =
  produceKafkaMessage
    (TopicName "account-created")
    Nothing
    AccountCreatedEvent
      { accountId = fromIntegral acctId,
        accountName = name,
        accountEmail = email
      }

publishWelcomeNotification :: HasKafkaProducer env => Text -> RIO env ()
publishWelcomeNotification email =
  produceKafkaMessage
    (TopicName "notifications")
    Nothing
    NotificationMessage
      { templateName = "welcome_email",
        variables =
          [ NotificationVariable {propertyName = "name", propertyValue = email},
            NotificationVariable {propertyName = "email", propertyValue = email},
            NotificationVariable {propertyName = "actionUrl", propertyValue = "http://localhost:5173"}
          ],
        channel = Email email
      }
