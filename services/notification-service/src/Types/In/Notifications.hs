{-# LANGUAGE NoOverloadedRecordDot #-}

module Types.In.Notifications
  ( NotificationChannel (..),
    NotificationVariable (..),
    NotificationMessage (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.=), (.:))
import qualified Data.Text as T
import RIO

-- | Supported notification delivery channels.
data NotificationChannel
  = Email !Text
  deriving stock (Show, Eq, Generic)

instance ToJSON NotificationChannel where
  toJSON (Email addr) = object ["channelType" .= ("email" :: Text), "channelAddress" .= addr]

instance FromJSON NotificationChannel where
  parseJSON = withObject "NotificationChannel" $ \o -> do
    t <- o .: "channelType"
    addr <- o .: "channelAddress"
    case (t :: Text) of
      "email" -> pure (Email addr)
      other -> fail $ "Unknown channelType: " <> T.unpack other

-- | A single template variable expressed as a named record.
data NotificationVariable = NotificationVariable
  { propertyName :: !Text,
    propertyValue :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Kafka message payload for dispatching a notification.
data NotificationMessage = NotificationMessage
  { templateName :: !Text,
    variables :: ![NotificationVariable],
    channel :: !NotificationChannel
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
