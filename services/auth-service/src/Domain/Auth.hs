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
  ( JWTSettings (..),
    issueAccessToken,
    issueAdminAccessToken,
    issueRefreshToken,
    verifyRefreshTokenJti,
  )
import Auth.Password (hashPassword, verifyPassword)
import Data.Time (addUTCTime, getCurrentTime, nominalDay)
import Database.Persist.Sql (Entity (..), fromSqlKey)
import Models.User (UserId)
import qualified Models.User as User
import Ports.Produce (publishUserRegistered)
import Ports.Repository
import RIO
import RIO.Text (unpack)
import Servant (err401, err409, err500, errBody)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))

-- | Constraint alias for auth domain functions.
type AuthDB env = (HasLogFunc env, HasLogContext env, HasDB env)

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
      let newUser =
            User.User
              { User.userEmail = email,
                User.userPasswordHash = passwordHash
              }
      userId <- createUser newUser
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
          now <- liftIO getCurrentTime
          at <-
            liftIO (issueAccessToken jwt (fromSqlKey userId) (User.userEmail user) now) >>= \case
              Left err -> throwM err500 {errBody = fromString (unpack err)}
              Right t -> return t
          return (at, jwtAccessTokenExpirySeconds jwt)

-- | Revoke a refresh token (logout). Silently succeeds on invalid tokens.
logout ::
  AuthDB env =>
  JWTSettings ->
  Text ->
  RIO env ()
logout jwt refreshToken = do
  logInfoC "Logout request"
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
  let issueAt = if email `elem` jwtAdminEmails jwt then issueAdminAccessToken else issueAccessToken

  at <- liftIO (issueAt jwt userIdInt email now) >>= \case
    Left err -> throwM err500 {errBody = fromString (unpack err)}
    Right t -> return t

  (jti, rt) <- liftIO (issueRefreshToken jwt userIdInt now) >>= \case
    Left err -> throwM err500 {errBody = fromString (unpack err)}
    Right pair -> return pair

  let expiresAt = addUTCTime (nominalDay * fromIntegral (jwtRefreshTokenExpiryDays jwt)) now
      storedToken =
        User.RefreshToken
          { User.refreshTokenJti = jti,
            User.refreshTokenUserId = userId,
            User.refreshTokenExpiresAt = expiresAt,
            User.refreshTokenRevoked = False,
            User.refreshTokenCreatedAt = now
          }
  storeRefreshToken storedToken
  logInfoC $ "Issued token pair for user: " <> displayShow userIdInt
  return (at, rt, jwtAccessTokenExpirySeconds jwt)
