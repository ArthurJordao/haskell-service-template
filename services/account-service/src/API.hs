module API (API, Account (..), CreateAccountRequest (..), AccountCreatedEvent (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Models.Account (Account (..))
import RIO
import Servant

data CreateAccountRequest = CreateAccountRequest
  { createAccountName :: !Text,
    createAccountEmail :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AccountCreatedEvent = AccountCreatedEvent
  { eventAccountId :: !Int,
    eventAccountName :: !Text,
    eventAccountEmail :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

type API =
  "status" :> Get '[JSON] Text
    :<|> "accounts" :> Get '[JSON] [Account]
    :<|> "accounts" :> Capture "id" Int :> Get '[JSON] Account
    :<|> "accounts" :> ReqBody '[JSON] CreateAccountRequest :> Post '[JSON] Account
