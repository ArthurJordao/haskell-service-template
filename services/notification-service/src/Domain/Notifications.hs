{-# LANGUAGE ConstraintKinds #-}

module Domain.Notifications
  ( Domain,
    HasTemplateCache (..),
    HasNotificationDir (..),
    NotificationChannel (..),
    NotificationMessage (..),
    NotificationVariable (..),
    processNotification,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Database.Persist (insert_)
import Models.SentNotification (SentNotification (..))
import RIO
import Service.CorrelationId (HasLogContext (..), logErrorC, logInfoC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Text.Mustache (Template, checkedSubstituteValue)
import Text.Mustache.Types (mFromJSON)

-- | Constraint alias for domain functions.
type Domain env = (HasLogFunc env, HasLogContext env, HasTemplateCache env, HasNotificationDir env, HasDB env)

-- | Read-only access to the loaded Mustache template cache.
class HasTemplateCache env where
  templateCacheL :: Lens' env (Map Text Template)

-- | Directory where dispatched notification files are written.
class HasNotificationDir env where
  notificationDirL :: Lens' env FilePath

-- ============================================================================
-- Domain types
-- ============================================================================

-- | Supported notification delivery channels.
data NotificationChannel
  = Email !Text -- ^ Recipient email address
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A single template variable expressed as a named record.
data NotificationVariable = NotificationVariable
  { propertyName :: !Text,
    propertyValue :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Kafka message payload for dispatching a notification.
data NotificationMessage = NotificationMessage
  { notifTemplateName :: !Text,
    notifVariables :: ![NotificationVariable],
    notifChannel :: !NotificationChannel
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ============================================================================
-- Domain logic
-- ============================================================================

-- | Render the named Mustache template with the provided variables,
-- dispatch via the chosen channel, and persist a record of the send.
--
-- Throws (→ dead letter) when:
--   * The template name is not found in the cache.
--   * One or more required template variables are missing from the message.
processNotification :: Domain env => NotificationMessage -> RIO env ()
processNotification msg = do
  cache <- view templateCacheL
  case Map.lookup (notifTemplateName msg) cache of
    Nothing -> do
      let errMsg = "Template not found: " <> notifTemplateName msg
      logErrorC $ display errMsg
      throwString (T.unpack errMsg)
    Just tmpl -> do
      let vars = Map.fromList [(propertyName v, propertyValue v) | v <- notifVariables msg]
          context = mFromJSON vars
          (errors, rendered) = checkedSubstituteValue tmpl context
      unless (null errors) $ do
        let errMsg = "Template substitution errors: " <> T.pack (show errors)
        logErrorC $ display errMsg
        throwString (T.unpack errMsg)
      now <- liftIO getCurrentTime
      dispatch now (notifChannel msg) (notifTemplateName msg) rendered
      recordSentNotification now (notifChannel msg) (notifTemplateName msg) rendered

-- ============================================================================
-- Dispatch
-- ============================================================================

-- | Write the rendered notification to a file in the notifications directory.
dispatch ::
  (HasLogFunc env, HasLogContext env, HasNotificationDir env) =>
  UTCTime ->
  NotificationChannel ->
  Text ->
  Text ->
  RIO env ()
dispatch now (Email recipient) tmplName rendered = do
  dir <- view notificationDirL
  liftIO $ createDirectoryIfMissing True dir
  let timeStr = formatTime defaultTimeLocale "%Y%m%d_%H%M%S_%q" now
      sanitized = T.unpack $ T.replace "@" "_at_" $ T.replace "." "_" recipient
      fileName = T.unpack tmplName <> "_email_" <> sanitized <> "_" <> timeStr <> ".txt"
      filePath = dir </> fileName
      content = "To: " <> recipient <> "\n\n" <> rendered
  writeFileUtf8 filePath content
  logInfoC $
    "Notification dispatched via Email to '"
      <> display recipient
      <> "' → "
      <> displayShow filePath

-- ============================================================================
-- Persistence
-- ============================================================================

-- | Insert a record of the sent notification into the database.
recordSentNotification ::
  (HasLogFunc env, HasLogContext env, HasDB env) =>
  UTCTime ->
  NotificationChannel ->
  Text ->
  Text ->
  RIO env ()
recordSentNotification now channel tmplName content = do
  pool <- view dbL
  let (channelType, recipient) = case channel of
        Email addr -> ("email", addr)
      record =
        SentNotification
          { sentNotificationTemplateName = tmplName,
            sentNotificationChannelType = channelType,
            sentNotificationRecipient = recipient,
            sentNotificationContent = content,
            sentNotificationSentAt = now
          }
  runSqlPoolWithCid (insert_ record) pool
