{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( findUserByEmail,
    createUser,
    findUserById,
    findRefreshTokenByJti,
    storeRefreshToken,
    revokeRefreshToken,
  )
where

import Database.Persist.Sql (Entity, get, getBy, insert, update, (=.))
import Models.User
  ( RefreshToken,
    RefreshTokenId,
    Unique (UniqueEmail, UniqueJti),
    User,
    UserId,
  )
import qualified Models.User as User
import RIO
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..), runSqlPoolWithCid)

type Repo env = (HasLogFunc env, HasLogContext env, HasDB env)

findUserByEmail :: Repo env => Text -> RIO env (Maybe (Entity User))
findUserByEmail email = do
  pool <- view dbL
  runSqlPoolWithCid (getBy (UniqueEmail email)) pool

createUser :: Repo env => User -> RIO env UserId
createUser user = do
  pool <- view dbL
  runSqlPoolWithCid (insert user) pool

findUserById :: Repo env => UserId -> RIO env (Maybe User)
findUserById uid = do
  pool <- view dbL
  runSqlPoolWithCid (get uid) pool

findRefreshTokenByJti :: Repo env => Text -> RIO env (Maybe (Entity RefreshToken))
findRefreshTokenByJti jti = do
  pool <- view dbL
  runSqlPoolWithCid (getBy (UniqueJti jti)) pool

storeRefreshToken :: Repo env => RefreshToken -> RIO env ()
storeRefreshToken token = do
  pool <- view dbL
  _ <- runSqlPoolWithCid (insert token) pool
  return ()

revokeRefreshToken :: Repo env => RefreshTokenId -> RIO env ()
revokeRefreshToken tokenId = do
  pool <- view dbL
  runSqlPoolWithCid (update tokenId [User.RefreshTokenRevoked =. True]) pool
