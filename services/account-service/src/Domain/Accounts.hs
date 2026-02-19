{-# LANGUAGE ConstraintKinds #-}

module Domain.Accounts
  ( Domain,
    listAccounts,
    getAccount,
    processUserRegistered,
  )
where

import Database.Persist.Sql (entityVal)
import Models.Account (Account (..))
import qualified Ports.Repository as Repo
import RIO
import Servant (err404, errBody)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))

-- | Constraint alias for domain functions that need DB access.
type Domain env = (HasLogFunc env, HasLogContext env, HasDB env)

-- | List all accounts.
listAccounts :: Domain env => RIO env [Account]
listAccounts = do
  logInfoC "Listing accounts"
  entities <- Repo.findAllAccounts
  return $ map entityVal entities

-- | Fetch a single account by auth user ID; throws 404 if not found.
getAccount :: Domain env => Int64 -> RIO env Account
getAccount authUserId = do
  logInfoC $ "Getting account for auth user: " <> displayShow authUserId
  mAccount <- Repo.findAccountByAuthUserId authUserId
  case mAccount of
    Nothing -> throwM err404 {errBody = "Account not found"}
    Just account -> return account

-- | Idempotently create an account for a newly registered user.
-- Called from the Kafka consumer when a user-registered event arrives.
processUserRegistered :: Domain env => Int64 -> Text -> RIO env ()
processUserRegistered uid email = do
  existing <- Repo.findAccountByAuthUserId uid
  case existing of
    Just _ -> logInfoC $ "Account already exists for user " <> displayShow uid
    Nothing -> do
      void $ Repo.createAccount Account {accountName = email, accountEmail = email, accountAuthUserId = uid}
      logInfoC $ "Created account for user " <> displayShow uid
