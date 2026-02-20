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

import Database.Persist.Sql (Entity, get, getBy, update, (=.))
import DB.User
  ( RefreshToken,
    RefreshTokenId,
    Unique (UniqueEmail, UniqueJti),
    User,
    UserId,
  )
import qualified DB.User as User
import RIO
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..))
import Service.Database (HasDB (..), insertWithMeta, insertWithMeta_, runSqlPoolWithCid)

type Repo env = (HasLogFunc env, HasLogContext env, HasDB env, HasCorrelationId env)

findUserByEmail :: Repo env => Text -> RIO env (Maybe (Entity User))
findUserByEmail email = do
  pool <- view dbL
  runSqlPoolWithCid (getBy (UniqueEmail email)) pool

createUser :: Repo env => User -> RIO env UserId
createUser = insertWithMeta

findUserById :: Repo env => UserId -> RIO env (Maybe User)
findUserById uid = do
  pool <- view dbL
  runSqlPoolWithCid (get uid) pool

findRefreshTokenByJti :: Repo env => Text -> RIO env (Maybe (Entity RefreshToken))
findRefreshTokenByJti jti = do
  pool <- view dbL
  runSqlPoolWithCid (getBy (UniqueJti jti)) pool

storeRefreshToken :: Repo env => RefreshToken -> RIO env ()
storeRefreshToken = insertWithMeta_

revokeRefreshToken :: Repo env => RefreshTokenId -> RIO env ()
revokeRefreshToken tokenId = do
  pool <- view dbL
  runSqlPoolWithCid (update tokenId [User.RefreshTokenRevoked =. True]) pool
