{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( findUserByEmail,
    createUser,
    findUserById,
    findRefreshTokenByJti,
    storeRefreshToken,
    revokeRefreshToken,
    insertDefaultScopes,
    listAllUsers,
    listScopes,
    getUserScopeNames,
    replaceUserScopes,
    bootstrapAdminScopeIfMissing,
  )
where

import qualified Data.Map.Strict as Map
import Database.Persist
  ( Entity (..),
    deleteWhere,
    get,
    getBy,
    selectList,
    update,
    (<-.),
    (=.),
    (==.),
  )
import DB.User
  ( RefreshToken,
    RefreshTokenId,
    Scope,
    Unique (UniqueEmail, UniqueJti, UniqueUserScope),
    User,
    UserId,
    UserScope,
    mkUserScope,
    userScopeScope,
    userScopeUserId,
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

-- ============================================================================
-- Scope queries
-- ============================================================================

-- | Insert default scopes for a newly registered user.
insertDefaultScopes :: Repo env => UserId -> RIO env ()
insertDefaultScopes userId =
  forM_ ["read:accounts:own", "write:accounts:own"] $ \scope ->
    insertWithMeta_ (mkUserScope userId scope Nothing)

-- | List all users paired with their current scope names.
listAllUsers :: Repo env => RIO env [(Entity User, [Text])]
listAllUsers = do
  pool <- view dbL
  users <- runSqlPoolWithCid (selectList [] []) pool
  let userIds = map entityKey users
  allScopes <- runSqlPoolWithCid (selectList [User.UserScopeUserId <-. userIds] []) pool
  let scopeMap =
        foldl'
          ( \m e ->
              let uid = userScopeUserId (entityVal e)
                  scp = userScopeScope (entityVal e)
               in Map.insertWith (<>) uid [scp] m
          )
          Map.empty
          allScopes
  return $ map (\u -> (u, fromMaybe [] (Map.lookup (entityKey u) scopeMap))) users

-- | List all available scopes from the catalog.
listScopes :: Repo env => RIO env [Entity Scope]
listScopes = do
  pool <- view dbL
  runSqlPoolWithCid (selectList [] []) pool

-- | Get scope names assigned to a user.
getUserScopeNames :: Repo env => UserId -> RIO env [Text]
getUserScopeNames userId = do
  pool <- view dbL
  rows <- runSqlPoolWithCid (selectList [User.UserScopeUserId ==. userId] []) pool
  return $ map (userScopeScope . entityVal) rows

-- | Replace all scopes for a user (delete then re-insert).
replaceUserScopes :: Repo env => UserId -> [Text] -> RIO env ()
replaceUserScopes userId scopes = do
  pool <- view dbL
  runSqlPoolWithCid (deleteWhere [User.UserScopeUserId ==. userId]) pool
  forM_ scopes $ \scope ->
    insertWithMeta_ (mkUserScope userId scope Nothing)

-- | Insert the admin scope for a user if they don't already have it.
bootstrapAdminScopeIfMissing :: Repo env => UserId -> RIO env ()
bootstrapAdminScopeIfMissing userId = do
  pool <- view dbL
  existing <- runSqlPoolWithCid (getBy (UniqueUserScope userId "admin")) pool
  case existing of
    Just _ -> return ()
    Nothing -> insertWithMeta_ (mkUserScope userId "admin" Nothing)
