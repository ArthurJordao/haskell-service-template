module Ports.Server
  ( API,
    Routes (..),
    RegisterRequest (..),
    LoginRequest (..),
    RefreshRequest (..),
    LogoutRequest (..),
    AuthTokens (..),
    HasConfig (..),
    server,
    module Service.Server,
  )
where

import Auth.JWT
  ( JWTSettings (..),
    issueAccessToken,
    issueRefreshToken,
    verifyRefreshTokenJti,
  )
import Auth.Password (hashPassword, verifyPassword)
import Data.Aeson (FromJSON, ToJSON)
import Data.Time (addUTCTime, getCurrentTime, nominalDay)
import Database.Persist.Sql (Entity (..), fromSqlKey)
import Models.User (UserId)
import qualified Models.User as User
import Ports.Produce (publishUserRegistered)
import Ports.Repository
import RIO
import RIO.Text (unpack)
import Servant
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))
import Service.Metrics (HasMetrics (..), metricsHandler)
import Service.Server

-- ============================================================================
-- API Types
-- ============================================================================

data RegisterRequest = RegisterRequest
  { registerEmail :: !Text,
    registerPassword :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LoginRequest = LoginRequest
  { loginEmail :: !Text,
    loginPassword :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RefreshRequest = RefreshRequest
  { refreshRequestToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LogoutRequest = LogoutRequest
  { logoutRefreshToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AuthTokens = AuthTokens
  { accessToken :: !Text,
    authRefreshToken :: !Text,
    tokenType :: !Text,
    expiresIn :: !Int
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ============================================================================
-- Routes
-- ============================================================================

data Routes route = Routes
  { status ::
      route
        :- Summary "Health check endpoint"
          :> "status"
          :> Get '[JSON] Text,
    register ::
      route
        :- Summary "Register a new user"
          :> "auth"
          :> "register"
          :> ReqBody '[JSON] RegisterRequest
          :> Post '[JSON] AuthTokens,
    login ::
      route
        :- Summary "Login with email and password"
          :> "auth"
          :> "login"
          :> ReqBody '[JSON] LoginRequest
          :> Post '[JSON] AuthTokens,
    refresh ::
      route
        :- Summary "Refresh access token using refresh token"
          :> "auth"
          :> "refresh"
          :> ReqBody '[JSON] RefreshRequest
          :> Post '[JSON] AuthTokens,
    logout ::
      route
        :- Summary "Revoke refresh token (logout)"
          :> "auth"
          :> "logout"
          :> ReqBody '[JSON] LogoutRequest
          :> Post '[JSON] NoContent,
    getMetrics ::
      route
        :- Summary "Prometheus metrics endpoint"
          :> "metrics"
          :> Get '[PlainText] Text
  }
  deriving stock (Generic)

type API = NamedRoutes Routes

-- ============================================================================
-- HasConfig (mirrors account-service pattern, extended with jwtSettings)
-- ============================================================================

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  httpSettings :: settings -> Settings
  jwtSettings :: settings -> JWTSettings

-- ============================================================================
-- Server
-- ============================================================================

server ::
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env,
    HasKafkaProducer env,
    HasMetrics env
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      register = registerHandler,
      login = loginHandler,
      refresh = refreshHandler,
      logout = logoutHandler,
      getMetrics = metricsEndpointHandler
    }

statusHandler ::
  forall env settings.
  (HasLogFunc env, HasLogContext env, HasConfig env settings) =>
  RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  let serverSettings = httpSettings @env @settings settings
  logInfoC ("Status OK, env=" <> displayShow (httpEnvironment serverSettings))
  return "OK"

registerHandler ::
  forall env settings.
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env,
    HasKafkaProducer env
  ) =>
  RegisterRequest ->
  RIO env AuthTokens
registerHandler req = do
  logInfoC $ "Register request for: " <> display (registerEmail req)
  existing <- findUserByEmail (registerEmail req)
  case existing of
    Just _ -> throwM err409 {errBody = "Email already registered"}
    Nothing -> do
      mHash <- liftIO $ hashPassword (registerPassword req)
      passwordHash <- maybe (throwM err500 {errBody = "Failed to hash password"}) return mHash
      let newUser =
            User.User
              { User.userEmail = registerEmail req,
                User.userPasswordHash = passwordHash
              }
      userId <- createUser newUser
      publishUserRegistered (fromSqlKey userId) (registerEmail req)
      issueTokenPair @env @settings userId (registerEmail req)

loginHandler ::
  forall env settings.
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env
  ) =>
  LoginRequest ->
  RIO env AuthTokens
loginHandler req = do
  logInfoC $ "Login request for: " <> display (loginEmail req)
  mUser <- findUserByEmail (loginEmail req)
  case mUser of
    Nothing -> throwM err401 {errBody = "Invalid credentials"}
    Just (Entity userId user) -> do
      unless (verifyPassword (User.userPasswordHash user) (loginPassword req)) $
        throwM err401 {errBody = "Invalid credentials"}
      logInfoC $ "Login successful for user ID: " <> displayShow (fromSqlKey userId :: Int64)
      issueTokenPair @env @settings userId (User.userEmail user)

refreshHandler ::
  forall env settings.
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env
  ) =>
  RefreshRequest ->
  RIO env AuthTokens
refreshHandler req = do
  logInfoC "Token refresh request"
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings

  jti <- liftIO (verifyRefreshTokenJti jwt (refreshRequestToken req)) >>= \case
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
          at <- liftIO (issueAccessToken jwt (fromSqlKey userId) (User.userEmail user) now) >>= \case
            Left err -> throwM err500 {errBody = fromString (unpack err)}
            Right t -> return t
          return
            AuthTokens
              { accessToken = at,
                authRefreshToken = refreshRequestToken req,
                tokenType = "Bearer",
                expiresIn = jwtAccessTokenExpirySeconds jwt
              }

logoutHandler ::
  forall env settings.
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env
  ) =>
  LogoutRequest ->
  RIO env NoContent
logoutHandler req = do
  logInfoC "Logout request"
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings

  jtiResult <- liftIO $ verifyRefreshTokenJti jwt (logoutRefreshToken req)
  case jtiResult of
    Left _ ->
      -- Token is invalid or expired; treat logout as successful
      return NoContent
    Right jti -> do
      mToken <- findRefreshTokenByJti jti
      case mToken of
        Just (Entity tokenId _) -> revokeRefreshToken tokenId
        Nothing -> return ()
      logInfoC $ "Revoked refresh token: " <> display jti
      return NoContent

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics

-- ============================================================================
-- Helpers
-- ============================================================================

issueTokenPair ::
  forall env settings.
  ( HasLogFunc env,
    HasLogContext env,
    HasConfig env settings,
    HasDB env
  ) =>
  UserId ->
  Text ->
  RIO env AuthTokens
issueTokenPair userId email = do
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  let userIdInt = fromSqlKey userId :: Int64
  now <- liftIO getCurrentTime

  at <- liftIO (issueAccessToken jwt userIdInt email now) >>= \case
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
  return
    AuthTokens
      { accessToken = at,
        authRefreshToken = rt,
        tokenType = "Bearer",
        expiresIn = jwtAccessTokenExpirySeconds jwt
      }
