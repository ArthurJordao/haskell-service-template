{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module API (API, Account (..)) where

import Data.Aeson (FromJSON, ToJSON)
import RIO
import Servant

type API =
  "status" :> Get '[JSON] Text
    :<|> "accounts" :> Get '[JSON] [Account]
    :<|> "accounts" :> Capture "id" Int :> Get '[JSON] Account

data Account = Account
  { accountId :: Int
  , accountName :: Text
  }
  deriving (Generic)

instance ToJSON Account

instance FromJSON Account
