module Ports.Server
  ( API,
    Routes (..),
    HasConfig (..),
    server,
    module Service.Server,
    module Types.In.Auth,
    module Types.Out.Auth,
  )
where

import Auth.JWT (JWTSettings (..))
import qualified Domain.Auth as Domain
import qualified Domain.Scopes as Scopes
import Database.Persist (Entity (..))
import Database.Persist.Sql (fromSqlKey, toSqlKey)
import DB.User (UserId)
import RIO
import Servant
import Servant.Server.Generic (AsServerT)
import Service.Auth (AccessTokenClaims, HasScopes)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Kafka (HasKafkaProducer (..))
import Service.Metrics (HasMetrics (..), metricsHandler)
import Service.Redis (HasRedis)
import Service.Server
import Types.In.Auth
import Types.In.Scopes
import Types.Out.Auth
import Types.Out.Scopes
import qualified DB.User as User

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
    listScopeCatalog ::
      route
        :- Summary "List all available scopes (admin)"
          :> "scopes"
          :> HasScopes '["admin"]
          :> Get '[JSON] [ScopeInfo],
    listUsers ::
      route
        :- Summary "List users with their scopes (admin)"
          :> "users"
          :> HasScopes '["admin"]
          :> Get '[JSON] [UserWithScopes],
    getUserScopes ::
      route
        :- Summary "Get scopes for a specific user (admin)"
          :> "users"
          :> Capture "id" Int64
          :> "scopes"
          :> HasScopes '["admin"]
          :> Get '[JSON] [Text],
    setUserScopes ::
      route
        :- Summary "Replace scopes for a specific user (admin)"
          :> "users"
          :> Capture "id" Int64
          :> "scopes"
          :> HasScopes '["admin"]
          :> ReqBody '[JSON] SetScopesRequest
          :> Put '[JSON] NoContent,
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
    HasMetrics env,
    HasCorrelationId env,
    HasRedis env
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      register = registerHandler,
      login = loginHandler,
      refresh = refreshHandler,
      logout = logoutHandler,
      listScopeCatalog = listScopeCatalogHandler,
      listUsers = listUsersHandler,
      getUserScopes = getUserScopesHandler,
      setUserScopes = setUserScopesHandler,
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
    HasKafkaProducer env,
    HasCorrelationId env
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
    HasDB env,
    HasCorrelationId env
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
    HasDB env,
    HasCorrelationId env
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
    HasDB env,
    HasCorrelationId env,
    HasRedis env
  ) =>
  LogoutRequest ->
  RIO env NoContent
logoutHandler req = do
  settings <- view (settingsL @env @settings)
  let jwt = jwtSettings @env @settings settings
  Domain.logout jwt req.refreshToken req.accessToken
  return NoContent

listScopeCatalogHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    HasCorrelationId env
  ) =>
  AccessTokenClaims ->
  RIO env [ScopeInfo]
listScopeCatalogHandler _claims = do
  entities <- Scopes.listAvailableScopes
  return $ map toScopeInfo entities
  where
    toScopeInfo e =
      ScopeInfo
        { id = fromSqlKey (entityKey e),
          name = User.scopeName (entityVal e),
          description = User.scopeDescription (entityVal e)
        }

listUsersHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    HasCorrelationId env
  ) =>
  AccessTokenClaims ->
  RIO env [UserWithScopes]
listUsersHandler _claims = do
  pairs <- Scopes.listUsersWithScopes
  return $ map toUserWithScopes pairs
  where
    toUserWithScopes (e, scopes) =
      UserWithScopes
        { id = fromSqlKey (entityKey e),
          email = User.userEmail (entityVal e),
          scopes = scopes
        }

getUserScopesHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    HasCorrelationId env
  ) =>
  Int64 ->
  AccessTokenClaims ->
  RIO env [Text]
getUserScopesHandler userId _claims =
  Scopes.getUserScopes (toSqlKey userId :: UserId)

setUserScopesHandler ::
  ( HasLogFunc env,
    HasLogContext env,
    HasDB env,
    HasCorrelationId env,
    HasRedis env
  ) =>
  Int64 ->
  AccessTokenClaims ->
  SetScopesRequest ->
  RIO env NoContent
setUserScopesHandler userId _claims req = do
  Scopes.setUserScopes (toSqlKey userId :: UserId) req.scopes
  return NoContent

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics
