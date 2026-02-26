module Types.Out.AccountCreated
  ( AccountCreatedEvent (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data AccountCreatedEvent = AccountCreatedEvent
  { accountId :: Int,
    accountName :: Text,
    accountEmail :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
