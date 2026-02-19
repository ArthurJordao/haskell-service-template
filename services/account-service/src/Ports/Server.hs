module Ports.Server
  ( API,
    Routes (..),
    ExternalPost (..),
    HasConfig (..),
    server,
    module Service.Server,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import qualified Domain.Accounts as Domain
import Models.Account (Account)
import RIO
import RIO.Text (pack)
import Servant
import Servant.Server.Generic (AsServerT)
import Service.Auth (RequireOwnerOrScopes)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.HttpClient (HasHttpClient, callServiceGet)
import Service.Metrics (HasMetrics (..), metricsHandler)
import Service.Server

-- ============================================================================
-- API Types
-- ============================================================================

data ExternalPost = ExternalPost
  { userId :: !Int,
    id :: !Int,
    title :: !Text,
    body :: !Text
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
    getAccounts ::
      route
        :- Summary "Get all accounts"
          :> "accounts"
          :> Get '[JSON] [Account],
    getAccountById ::
      route
        :- Summary "Get account by ID"
          :> "accounts"
          :> RequireOwnerOrScopes "id" Int64 '["admin"]
          :> Get '[JSON] Account,
    getExternalPost ::
      route
        :- Summary "Example: Fetch external post via HTTP client"
          :> "external"
          :> "posts"
          :> Capture "id" Int
          :> Get '[JSON] ExternalPost,
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

-- ============================================================================
-- Server (thin adapter — delegates to Domain)
-- ============================================================================

server ::
  ( HasLogFunc env,
    HasLogContext env,
    HasCorrelationId env,
    HasConfig env settings,
    HasDB env,
    HasHttpClient env,
    HasMetrics env
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      getAccounts = Domain.listAccounts,
      getAccountById = \accId _claims -> Domain.getAccount accId,
      getExternalPost = externalPostHandler,
      getMetrics = metricsEndpointHandler
    }

statusHandler ::
  forall env settings.
  (HasLogFunc env, HasLogContext env, HasConfig env settings) =>
  RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  let serverSettings = httpSettings @env @settings settings
  logInfoC ("Status endpoint called env level" <> displayShow (httpEnvironment serverSettings))
  return "OK"

externalPostHandler ::
  (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasHttpClient env) =>
  Int ->
  RIO env ExternalPost
externalPostHandler postId = do
  logInfoC $ "Fetching external post with ID: " <> displayShow postId
  let url = "https://jsonplaceholder.typicode.com/posts/" <> pack (show postId)
  result <- callServiceGet url []
  case result of
    Left err -> do
      logInfoC $ "Failed to fetch external post: " <> displayShow err
      throwM err500 {errBody = "Failed to fetch external post"}
    Right post -> do
      logInfoC $ "Successfully fetched external post: " <> displayShow (title post)
      return post

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics
