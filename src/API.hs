module API (API, Account (..)) where

import Models.Account (Account (..))
import RIO
import Servant

type API =
  "status" :> Get '[JSON] Text
    :<|> "accounts" :> Get '[JSON] [Account]
    :<|> "accounts" :> Capture "id" Int :> Get '[JSON] Account
