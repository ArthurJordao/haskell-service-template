{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE NoOverloadedRecordDot #-}

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

import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import DB.SentNotification (mkSentNotification)
import RIO
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logErrorC, logInfoC)
import Service.Database (HasDB (..), insertWithMeta_)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Text.Mustache (Template, checkedSubstituteValue)
import Text.Mustache.Types (mFromJSON)
import Types.In.Notifications

-- | Constraint alias for domain functions.
type Domain env = (HasLogFunc env, HasLogContext env, HasTemplateCache env, HasNotificationDir env, HasDB env, HasCorrelationId env)

-- | Read-only access to the loaded Mustache template cache.
class HasTemplateCache env where
  templateCacheL :: Lens' env (Map Text Template)

-- | Directory where dispatched notification files are written.
class HasNotificationDir env where
  notificationDirL :: Lens' env FilePath

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
  let recipient = case channel msg of Email addr -> addr
  when ("@fail.com" `T.isSuffixOf` recipient) $ do
    let errMsg = "Simulated notification failure for @fail.com address: " <> recipient
    logErrorC $ display errMsg
    throwString (T.unpack errMsg)
  cache <- view templateCacheL
  case Map.lookup (templateName msg) cache of
    Nothing -> do
      let errMsg = "Template not found: " <> templateName msg
      logErrorC $ display errMsg
      throwString (T.unpack errMsg)
    Just tmpl -> do
      let vars = Map.fromList [(propertyName v, propertyValue v) | v <- variables msg]
          context = mFromJSON vars
          (errors, rendered) = checkedSubstituteValue tmpl context
      unless (null errors) $ do
        let errMsg = "Template substitution errors: " <> T.pack (show errors)
        logErrorC $ display errMsg
        throwString (T.unpack errMsg)
      now <- liftIO getCurrentTime
      dispatch now (channel msg) (templateName msg) rendered
      recordSentNotification (channel msg) (templateName msg) rendered

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
  (HasLogFunc env, HasLogContext env, HasDB env, HasCorrelationId env) =>
  NotificationChannel ->
  Text ->
  Text ->
  RIO env ()
recordSentNotification ch tmplName content = do
  let (chType, recipient) = case ch of Email addr -> ("email", addr)
  insertWithMeta_ (mkSentNotification tmplName chType recipient content)
