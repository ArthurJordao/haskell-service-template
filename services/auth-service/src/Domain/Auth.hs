{-# LANGUAGE ConstraintKinds #-}

module Domain.Auth
  ( AuthDB,
    register,
    login,
    refreshAccessToken,
    logout,
  )
where

import Auth.JWT
  ( AccessTokenClaims (..),
    JWTSettings (..),
    issueAccessToken,
    issueRefreshToken,
    verifyAccessToken,
    verifyRefreshTokenJti,
  )
import Auth.Password (hashPassword, verifyPassword)
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime, nominalDay)
import Database.Persist.Sql (Entity (..), fromSqlKey)
import DB.User (UserId, mkRefreshToken, mkUser)
import qualified DB.User as User
import Ports.Produce (publishUserRegistered)
import Ports.Repository
import RIO
import RIO.Text (unpack)
import Servant (err401, err409, err500, errBody)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))
import Service.Redis (HasRedis, revokeJti)

-- | Constraint alias for auth domain functions.
type AuthDB env = (HasLogFunc env, HasLogContext env, HasDB env, HasCorrelationId env)

-- | Register a new user; returns (accessToken, refreshToken, expiresIn).
-- Throws 409 if the email is already registered.
register ::
  (AuthDB env, HasKafkaProducer env) =>
  JWTSettings ->
  Text ->
  Text ->
  RIO env (Text, Text, Int)
register jwt email password = do
  logInfoC $ "Register request for: " <> display email
  existing <- findUserByEmail email
  case existing of
    Just _ -> throwM err409 {errBody = "Email already registered"}
    Nothing -> do
      mHash <- liftIO $ hashPassword password
      passwordHash <- maybe (throwM err500 {errBody = "Failed to hash password"}) return mHash
      userId <- createUser (mkUser email passwordHash)
      insertDefaultScopes userId
      publishUserRegistered (fromSqlKey userId) email
      issueTokenPair jwt userId email

-- | Log in with email and password; returns (accessToken, refreshToken, expiresIn).
-- Throws 401 on invalid credentials.
login ::
  AuthDB env =>
  JWTSettings ->
  Text ->
  Text ->
  RIO env (Text, Text, Int)
login jwt email password = do
  logInfoC $ "Login request for: " <> display email
  mUser <- findUserByEmail email
  case mUser of
    Nothing -> throwM err401 {errBody = "Invalid credentials"}
    Just (Entity userId user) -> do
      unless (verifyPassword (User.userPasswordHash user) password) $
        throwM err401 {errBody = "Invalid credentials"}
      logInfoC $ "Login successful for user ID: " <> displayShow (fromSqlKey userId :: Int64)
      issueTokenPair jwt userId (User.userEmail user)

-- | Issue a fresh access token for a valid refresh token.
-- Returns (newAccessToken, expiresIn); the refresh token itself is unchanged.
-- Throws 401 if the token is invalid, expired, or revoked.
refreshAccessToken ::
  AuthDB env =>
  JWTSettings ->
  Text ->
  RIO env (Text, Int)
refreshAccessToken jwt refreshToken = do
  logInfoC "Token refresh request"
  jti <-
    liftIO (verifyRefreshTokenJti jwt refreshToken) >>= \case
      Left err -> throwM err401 {errBody = fromString (unpack err)}
      Right j -> return j

  mToken <- findRefreshTokenByJti jti
  case mToken of
    Nothing -> throwM err401 {errBody = "Refresh token not found"}
    Just (Entity _ token) -> do
      when (User.refreshTokenRevoked token) $
        throwM err401 {errBody = "Refresh token has been revoked"}
      let userId = User.refreshTokenUserId token
      mUser <- findUserById userId
      case mUser of
        Nothing -> throwM err500 {errBody = "User not found"}
        Just user -> do
          scopes <- getUserScopeNames userId
          when (User.userEmail user `elem` jwtAdminEmails jwt && "admin" `notElem` scopes) $
            bootstrapAdminScopeIfMissing userId
          finalScopes <- getUserScopeNames userId
          now <- liftIO getCurrentTime
          at <-
            liftIO (issueAccessToken jwt (fromSqlKey userId) (User.userEmail user) finalScopes now) >>= \case
              Left err -> throwM err500 {errBody = fromString (unpack err)}
              Right t -> return t
          return (at, jwtAccessTokenExpirySeconds jwt)

-- | Revoke a refresh token (logout).
-- If an access token is provided, its JTI is also added to the Redis denylist.
-- Silently succeeds on invalid tokens.
logout ::
  (AuthDB env, HasRedis env) =>
  JWTSettings ->
  Text ->
  Maybe Text ->
  RIO env ()
logout jwt refreshToken mAccessToken = do
  logInfoC "Logout request"

  -- Revoke access token JTI in Redis if token is provided and valid.
  case mAccessToken of
    Nothing -> return ()
    Just at ->
      liftIO (verifyAccessToken jwt at) >>= \case
        Left _ -> return () -- invalid/expired token; nothing to revoke
        Right claims -> do
          now <- liftIO getCurrentTime
          let expiry = addUTCTime (fromIntegral (jwtAccessTokenExpirySeconds jwt)) (atcIssuedAt claims)
              remaining = max 0 (round (diffUTCTime expiry now) :: Int)
          when (remaining > 0) $ revokeJti (atcJti claims) remaining

  -- Revoke refresh token in DB.
  jtiResult <- liftIO $ verifyRefreshTokenJti jwt refreshToken
  case jtiResult of
    Left _ ->
      -- Token is invalid or expired; treat logout as already done.
      return ()
    Right jti -> do
      mToken <- findRefreshTokenByJti jti
      case mToken of
        Just (Entity tokenId _) -> revokeRefreshToken tokenId
        Nothing -> return ()
      logInfoC $ "Revoked refresh token: " <> display jti

-- ============================================================================
-- Private helpers
-- ============================================================================

issueTokenPair ::
  AuthDB env =>
  JWTSettings ->
  UserId ->
  Text ->
  RIO env (Text, Text, Int)
issueTokenPair jwt userId email = do
  let userIdInt = fromSqlKey userId :: Int64
  now <- liftIO getCurrentTime

  -- Get DB-backed scopes, with admin bootstrap if the email is in the admin list.
  scopes <- getUserScopeNames userId
  when (email `elem` jwtAdminEmails jwt && "admin" `notElem` scopes) $
    bootstrapAdminScopeIfMissing userId
  finalScopes <- getUserScopeNames userId

  at <- liftIO (issueAccessToken jwt userIdInt email finalScopes now) >>= \case
    Left err -> throwM err500 {errBody = fromString (unpack err)}
    Right t -> return t

  (jti, rt) <- liftIO (issueRefreshToken jwt userIdInt now) >>= \case
    Left err -> throwM err500 {errBody = fromString (unpack err)}
    Right pair -> return pair

  let expiresAt = addUTCTime (nominalDay * fromIntegral (jwtRefreshTokenExpiryDays jwt)) now
  storeRefreshToken (mkRefreshToken jti userId expiresAt False)
  logInfoC $ "Issued token pair for user: " <> displayShow userIdInt
  return (at, rt, jwtAccessTokenExpirySeconds jwt)
