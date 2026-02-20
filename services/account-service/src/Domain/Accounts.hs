{-# LANGUAGE ConstraintKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Domain.Accounts
  ( Domain,
    listAccounts,
    getAccount,
    processUserRegistered,
  )
where

import Database.Persist.Sql (entityVal)
import DB.Account (Account (..), mkAccount)
import qualified Ports.Repository as Repo
import RIO
import RIO.Text (pack)
import Servant (err404, errBody)
import Service.Auth (AccessTokenClaims (..))
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Policy (AccessPolicy (..), authorize)

-- | Constraint alias for domain functions that need DB access.
type Domain env = (HasLogFunc env, HasLogContext env, HasDB env, HasCorrelationId env)

-- | Who may access an Account record.
-- Owner: JWT subject matches "user-{authUserId}".
-- Admin: JWT carries the "admin" scope.
instance AccessPolicy Account where
  canAccess claims account =
    "admin" `elem` atcScopes claims
      || "user-" <> pack (show (accountAuthUserId account)) == atcSubject claims

-- | List all accounts.
listAccounts :: Domain env => RIO env [Account]
listAccounts = do
  logInfoC "Listing accounts"
  entities <- Repo.findAllAccounts
  return $ map entityVal entities

-- | Fetch a single account by its DB primary key.
-- Throws 403 unless the caller owns the account or has "admin" scope.
getAccount :: Domain env => Int64 -> AccessTokenClaims -> RIO env Account
getAccount accId claims = do
  logInfoC $ "Getting account: " <> displayShow accId
  mAccount <- Repo.findAccountById accId
  case mAccount of
    Nothing -> throwM err404 {errBody = "Account not found"}
    Just account -> do
      authorize claims account
      return account

-- | Idempotently create an account for a newly registered user.
-- Called from the Kafka consumer when a user-registered event arrives.
processUserRegistered :: Domain env => Int64 -> Text -> RIO env ()
processUserRegistered uid email = do
  existing <- Repo.findAccountByAuthUserId uid
  case existing of
    Just _ -> logInfoC $ "Account already exists for user " <> displayShow uid
    Nothing -> do
      void $ Repo.createAccount (mkAccount email email uid)
      logInfoC $ "Created account for user " <> displayShow uid
