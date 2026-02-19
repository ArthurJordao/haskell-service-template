{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( Repo,
    findAllAccounts,
    findAccountById,
    findAccountByKey,
    createAccount,
    insertAccountWithKey,
  )
where

import Database.Persist.Sql (Entity, get, insert, insertKey, selectList, toSqlKey)
import Models.Account (Account, AccountId)
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

findAccountByKey :: Repo env => AccountId -> RIO env (Maybe Account)
findAccountByKey key = do
  pool <- view dbL
  runSqlPoolWithCid (get key) pool

createAccount :: Repo env => Account -> RIO env AccountId
createAccount account = do
  pool <- view dbL
  runSqlPoolWithCid (insert account) pool

insertAccountWithKey :: Repo env => AccountId -> Account -> RIO env ()
insertAccountWithKey key account = do
  pool <- view dbL
  runSqlPoolWithCid (insertKey key account) pool
