module Ports.Server
  ( API,
    Routes (..),
    HasConfig (..),
    server,
    module Service.Server,
  )
where

import RIO
import Servant
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Server

-- ============================================================================
-- Routes
-- ============================================================================

data Routes route = Routes
  { status ::
      route
        :- Summary "Health check endpoint"
          :> "status"
          :> Get '[JSON] Text
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
    HasConfig env settings
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler
    }

statusHandler ::
  forall env settings.
  (HasLogFunc env, HasLogContext env, HasConfig env settings) =>
  RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  logInfoC ("Status OK, env=" <> displayShow (httpEnvironment (httpSettings @env @settings settings)))
  return "OK"
