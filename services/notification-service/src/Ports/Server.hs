module Ports.Server
  ( API,
    Routes (..),
    HasConfig (..),
    server,
    module Service.Server,
    module Types.Out.Notifications,
  )
where

import Database.Persist.Sql (Entity (..), fromSqlKey)
import DB.SentNotification (SentNotification (..))
import qualified Ports.Repository as Repo
import RIO
import Servant
import Servant.Server.Generic (AsServerT)
import Service.Auth (HasScopes)
import Service.CorrelationId (HasLogContext (..), logInfoC)
import Service.Database (HasDB (..))
import Service.Server
import Types.Out.Notifications

-- ============================================================================
-- Routes
-- ============================================================================

data Routes route = Routes
  { status ::
      route
        :- Summary "Health check endpoint"
          :> "status"
          :> Get '[JSON] Text,
    listNotifications ::
      route
        :- Summary "List sent notifications for a recipient"
          :> "notifications"
          :> HasScopes '["admin"]
          :> QueryParam "recipient" Text
          :> Get '[JSON] [SentNotificationResponse]
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
    HasDB env,
    HasConfig env settings
  ) =>
  Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      listNotifications = \_claims -> listNotificationsHandler
    }

statusHandler ::
  forall env settings.
  (HasLogFunc env, HasLogContext env, HasConfig env settings) =>
  RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  logInfoC ("Status OK, env=" <> displayShow (httpEnvironment (httpSettings @env @settings settings)))
  return "OK"

listNotificationsHandler ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  Maybe Text ->
  RIO env [SentNotificationResponse]
listNotificationsHandler maybeRecipient = do
  let recipient = fromMaybe "" maybeRecipient
  logInfoC $ "Listing notifications for recipient=" <> display recipient
  entities <- Repo.getNotificationsByRecipient recipient
  return $ map entityToResponse entities

-- ============================================================================
-- Helpers
-- ============================================================================

entityToResponse :: Entity SentNotification -> SentNotificationResponse
entityToResponse (Entity key sn) =
  SentNotificationResponse
    { id = fromSqlKey key,
      templateName = sentNotificationTemplateName sn,
      channelType = sentNotificationChannelType sn,
      recipient = sentNotificationRecipient sn,
      content = sentNotificationContent sn,
      createdAt = sentNotificationCreatedAt sn,
      createdByCid = sentNotificationCreatedByCid sn
    }
