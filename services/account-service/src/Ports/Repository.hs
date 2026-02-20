{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( Repo,
    findAllAccounts,
    findAccountById,
    findAccountByAuthUserId,
    createAccount,
  )
where

import Database.Persist.Sql (Entity, entityVal, get, getBy, insert, selectList, toSqlKey)
import DB.Account (Account, AccountId, Unique (UniqueAuthUserId))
import RIO
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..), runSqlPoolWithCid)

type Repo env = (HasLogFunc env, HasLogContext env, HasDB env)

findAllAccounts :: Repo env => RIO env [Entity Account]
findAllAccounts = do
  pool <- view dbL
  runSqlPoolWithCid (selectList [] []) pool

findAccountById :: Repo env => Int64 -> RIO env (Maybe Account)
findAccountById accId = do
  pool <- view dbL
  runSqlPoolWithCid (get (toSqlKey accId :: AccountId)) pool

findAccountByAuthUserId :: Repo env => Int64 -> RIO env (Maybe Account)
findAccountByAuthUserId uid = do
  pool <- view dbL
  fmap entityVal <$> runSqlPoolWithCid (getBy (UniqueAuthUserId uid)) pool

createAccount :: Repo env => Account -> RIO env AccountId
createAccount account = do
  pool <- view dbL
  runSqlPoolWithCid (insert account) pool
