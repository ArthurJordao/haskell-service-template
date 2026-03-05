{-# LANGUAGE ConstraintKinds #-}

module Domain.Scopes
  ( ScopesDB,
    listAvailableScopes,
    getUserScopes,
    setUserScopes,
    listUsersWithScopes,
  )
where

import Database.Persist (Entity)
import Database.Persist.Sql (fromSqlKey)
import DB.User (Scope, User, UserId)
import Ports.Repository
  ( getUserScopeNames,
    listAllUsers,
    listScopes,
    replaceUserScopes,
  )
import RIO
import RIO.Text (pack)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..))
import Service.Database (HasDB (..))
import Service.Redis (HasRedis, invalidateUserTokens)

type ScopesDB env =
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    HasCorrelationId env
  )

-- | List all scopes in the scope catalog.
listAvailableScopes :: ScopesDB env => RIO env [Entity Scope]
listAvailableScopes = listScopes

-- | Get scope names for a user.
getUserScopes :: ScopesDB env => UserId -> RIO env [Text]
getUserScopes = getUserScopeNames

-- | Replace a user's scopes and invalidate their existing tokens via Redis.
setUserScopes :: (ScopesDB env, HasRedis env) => UserId -> [Text] -> RIO env ()
setUserScopes userId scopes = do
  replaceUserScopes userId scopes
  let userIdText = "user-" <> pack (show (fromSqlKey userId :: Int64))
  invalidateUserTokens userIdText

-- | List all users with their current scopes (for admin UI).
listUsersWithScopes :: ScopesDB env => RIO env [(Entity User, [Text])]
listUsersWithScopes = listAllUsers
