{-# LANGUAGE ConstraintKinds #-}

module Domain.Accounts
  ( Domain,
    listAccounts,
    getAccount,
    createAccount,
    processUserRegistered,
  )
where

import Database.Persist.Sql (entityVal, fromSqlKey, toSqlKey)
import Models.Account (Account (..), AccountId)
import Ports.Produce (publishAccountCreated)
import qualified Ports.Repository as Repo
import RIO
import Servant (err404, errBody)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))

-- | Constraint alias for domain functions that need DB access.
type Domain env = (HasLogFunc env, HasLogContext env, HasDB env)

-- | List all accounts.
listAccounts :: Domain env => RIO env [Account]
listAccounts = do
  logInfoC "Listing accounts"
  entities <- Repo.findAllAccounts
  return $ map entityVal entities

-- | Fetch a single account by ID; throws 404 if not found.
getAccount :: Domain env => Int64 -> RIO env Account
getAccount accId = do
  logInfoC $ "Getting account: " <> displayShow accId
  mAccount <- Repo.findAccountById accId
  case mAccount of
    Nothing -> throwM err404 {errBody = "Account not found"}
    Just account -> return account

-- | Create a new account and publish an event.
createAccount :: (Domain env, HasKafkaProducer env) => Text -> Text -> RIO env Account
createAccount name email = do
  logInfoC $ "Creating account: " <> displayShow name
  let newAccount = Account {accountName = name, accountEmail = email}
  accountId <- Repo.createAccount newAccount
  publishAccountCreated (fromSqlKey accountId) name email
  return newAccount

-- | Idempotently create an account for a newly registered user.
-- Called from the Kafka consumer when a user-registered event arrives.
processUserRegistered :: Domain env => Int64 -> Text -> RIO env ()
processUserRegistered uid email = do
  let key = toSqlKey uid :: AccountId
  existing <- Repo.findAccountByKey key
  case existing of
    Just _ -> logInfoC $ "Account already exists for user " <> displayShow uid
    Nothing -> do
      Repo.insertAccountWithKey key Account {accountName = email, accountEmail = email}
      logInfoC $ "Created account for user " <> displayShow uid
