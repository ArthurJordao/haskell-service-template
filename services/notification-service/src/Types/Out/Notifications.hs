module Types.Out.Notifications
  ( SentNotificationResponse (..),
  )
where

import Data.Aeson (ToJSON)
import Data.Time.Clock (UTCTime)
import RIO

data SentNotificationResponse = SentNotificationResponse
  { id :: Int64,
    templateName :: Text,
    channelType :: Text,
    recipient :: Text,
    content :: Text,
    createdAt :: UTCTime,
    createdByCid :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)
