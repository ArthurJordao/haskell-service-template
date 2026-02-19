{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Service.Events (UserRegisteredEvent (..)) where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data UserRegisteredEvent = UserRegisteredEvent
  { ureUserId :: !Int64
  , ureEmail  :: !Text
  } deriving (Show, Eq, Generic)

instance FromJSON UserRegisteredEvent

instance ToJSON UserRegisteredEvent
