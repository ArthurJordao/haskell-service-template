module Types.Out.UserRegistered
  ( UserRegisteredEvent (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data UserRegisteredEvent = UserRegisteredEvent
  { userId :: !Int64,
    email :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
