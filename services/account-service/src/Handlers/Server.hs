module Handlers.Server (
  server,
  module Service.Server,
  HasConfig (..),
) where

import API
import Database.Persist.Sql (Entity (..), entityVal, fromSqlKey, get, insert, selectList, toSqlKey)
import Database.Persist.Sqlite (ConnectionPool)
import Service.Kafka (HasKafkaProducer (..))
import Service.Server
import Kafka.Consumer (TopicName (..))
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Models.Account (Account (..), AccountId)
import RIO
import Servant


server :: (HasLogFunc env, HasLogContext env, HasConfig env settings, HasDB env, HasKafkaProducer env) => ServerT API (RIO env)
server =
  statusHandler
    :<|> accountsHandler
    :<|> accountByIdHandler
    :<|> createAccountHandler

statusHandler :: forall env settings. (HasLogFunc env, HasLogContext env, HasConfig env settings) => RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  let httpSettings = http @env @settings settings
  logInfoC ("Status endpoint called env level" <> displayShow (httpEnvironment httpSettings))
  return "OK"

accountsHandler :: (HasLogFunc env, HasLogContext env, HasDB env) => RIO env [Account]
accountsHandler = do
  logInfoC "Accounts endpoint called"
  pool <- view dbL
  accounts <- runSqlPoolWithCid (selectList [] []) pool
  return $ map entityVal accounts

accountByIdHandler :: (HasLogFunc env, HasLogContext env, HasDB env) => Int -> RIO env Account
accountByIdHandler accId = do
  logInfoC $ "Account endpoint called with ID: " <> displayShow accId
  pool <- view dbL
  maybeAccount <- runSqlPoolWithCid (get (toSqlKey (fromIntegral accId) :: AccountId)) pool
  case maybeAccount of
    Just account -> return account
    Nothing -> throwM err404 {errBody = "Account not found"}

createAccountHandler :: (HasLogFunc env, HasLogContext env, HasDB env, HasKafkaProducer env) => CreateAccountRequest -> RIO env Account
createAccountHandler req = do
  logInfoC $ "Creating account: " <> displayShow (createAccountName req)
  pool <- view dbL

  let newAccount = Account
        { accountName = createAccountName req
        , accountEmail = createAccountEmail req
        }

  accountId <- runSqlPoolWithCid (insert newAccount) pool
  let accountIdInt :: Int
      accountIdInt = fromIntegral $ fromSqlKey accountId


  let event = AccountCreatedEvent
        { eventAccountId = accountIdInt
        , eventAccountName = createAccountName req
        , eventAccountEmail = createAccountEmail req
        }

  produceKafkaMessage (TopicName "account-created") Nothing event
  logInfoC $ "Published account-created event for account ID: " <> displayShow accountIdInt

  return newAccount

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  http :: settings -> Settings
