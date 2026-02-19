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

import Auth.JWT (JWTSettings (..))
import Data.Aeson (FromJSON, ToJSON)
import qualified Domain.Auth as Domain
import RIO
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
  { email :: !Text,
    password :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LoginRequest = LoginRequest
  { email :: !Text,
    password :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RefreshRequest = RefreshRequest
  { refreshToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LogoutRequest = LogoutRequest
  { refreshToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AuthTokens = AuthTokens
  { accessToken :: !Text,
    refreshToken :: !Text,
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
-- HasConfig
-- ============================================================================

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  httpSettings :: settings -> Settings
  jwtSettings :: settings -> JWTSettings

-- ============================================================================
-- Server (thin adapter — delegates to Domain)
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
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  (at, rt, expiresIn_) <- Domain.register jwt req.email req.password
  return AuthTokens {accessToken = at, refreshToken = rt, tokenType = "Bearer", expiresIn = expiresIn_}

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
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  (at, rt, expiresIn_) <- Domain.login jwt req.email req.password
  return AuthTokens {accessToken = at, refreshToken = rt, tokenType = "Bearer", expiresIn = expiresIn_}

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
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  (at, expiresIn_) <- Domain.refreshAccessToken jwt req.refreshToken
  return
    AuthTokens
      { accessToken = at,
        refreshToken = req.refreshToken,
        tokenType = "Bearer",
        expiresIn = expiresIn_
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
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  Domain.logout jwt req.refreshToken
  return NoContent

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics
