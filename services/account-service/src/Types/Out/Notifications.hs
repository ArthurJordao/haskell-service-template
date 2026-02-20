{-# LANGUAGE NoOverloadedRecordDot #-}

module Types.Out.Notifications
  ( NotificationChannel (..),
    NotificationVariable (..),
    NotificationMessage (..),
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import RIO

-- | Supported notification delivery channels.
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
  { templateName :: !Text,
    variables :: ![NotificationVariable],
    channel :: !NotificationChannel
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)
