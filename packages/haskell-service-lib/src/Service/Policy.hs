module Service.Policy
  ( AccessPolicy (..),
    authorize,
  )
where

import RIO
import Servant (err403, errBody)
import Service.Auth (AccessTokenClaims)

-- | Resource-level authorization policy.
--
-- Define an instance for each resource type to encode who may access it.
-- Unlike request-level policies ('Service.Auth.IsOwner', 'Service.Auth.HasScope'),
-- this check runs in the domain layer after the resource has been fetched from
-- the database, so it can inspect any field on the resource.
--
-- Example:
--
-- @
-- instance AccessPolicy Account where
--   canAccess claims account =
--     "admin" `elem` atcScopes claims
--       || "user-" <> pack (show (accountAuthUserId account)) == atcSubject claims
-- @
class AccessPolicy resource where
  canAccess :: AccessTokenClaims -> resource -> Bool

-- | Throw 403 Forbidden if the claims do not satisfy the resource's 'AccessPolicy'.
-- Call this in domain functions after fetching the resource.
authorize :: (AccessPolicy r, MonadIO m, MonadThrow m) => AccessTokenClaims -> r -> m ()
authorize claims resource =
  unless (canAccess claims resource) $
    throwM err403 {errBody = "Forbidden"}
