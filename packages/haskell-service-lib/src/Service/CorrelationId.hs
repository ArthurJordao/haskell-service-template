module Service.CorrelationId
  ( CorrelationId (..),
    HasCorrelationId (..),
    HasLogContext (..),
    defaultCorrelationId,
    generateCorrelationId,
    appendCorrelationId,
    correlationIdMiddleware,
    requestLoggingMiddleware,
    extractCorrelationId,
    logInfoC,
    logWarnC,
    logErrorC,
    logDebugC,
  )
where

import Control.Monad (replicateM)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vault.Lazy as Vault
import GHC.Stack (HasCallStack, withFrozenCallStack)
import Network.HTTP.Types (statusCode)
import Network.Wai (Middleware, Request, rawPathInfo, requestHeaders, requestMethod, responseStatus, vault)
import qualified Network.Wai as Wai
import RIO
import qualified RIO.ByteString as BS
import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomRIO)
import Prelude ((!!))

newtype CorrelationId = CorrelationId {unCorrelationId :: Text}
  deriving (Show, Eq)

defaultCorrelationId :: CorrelationId
defaultCorrelationId = CorrelationId "DEFAULT"

class HasCorrelationId env where
  correlationIdL :: Lens' env CorrelationId

class HasLogContext env where
  logContextL :: Lens' env (Map Text Text)

generateCorrelationId :: (MonadIO m) => m CorrelationId
generateCorrelationId = liftIO $ do
  let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
      charsList = T.unpack chars
  ids <- replicateM 6 $ do
    idx <- randomRIO (0, length charsList - 1)
    return (charsList !! idx)
  return $ CorrelationId $ T.pack ids

appendCorrelationId :: (MonadIO m) => CorrelationId -> m CorrelationId
appendCorrelationId (CorrelationId existingCid) = do
  newSegment <- generateCorrelationId
  return $ CorrelationId $ existingCid <> "." <> unCorrelationId newSegment

formatContext :: Map Text Text -> Utf8Builder
formatContext ctx
  | Map.null ctx = mempty
  | otherwise = "[" <> mconcat (map formatEntry (Map.toList ctx)) <> "] "
  where
    formatEntry (key, value) = fromString (T.unpack key) <> "=" <> fromString (T.unpack value) <> " "

logInfoC :: (HasCallStack, HasLogFunc env, HasLogContext env, MonadReader env m, MonadIO m) => Utf8Builder -> m ()
logInfoC msg = withFrozenCallStack $ do
  ctx <- view logContextL
  logInfo $ formatContext ctx <> msg

logWarnC :: (HasCallStack, HasLogFunc env, HasLogContext env, MonadReader env m, MonadIO m) => Utf8Builder -> m ()
logWarnC msg = withFrozenCallStack $ do
  ctx <- view logContextL
  logWarn $ formatContext ctx <> msg

logErrorC :: (HasCallStack, HasLogFunc env, HasLogContext env, MonadReader env m, MonadIO m) => Utf8Builder -> m ()
logErrorC msg = withFrozenCallStack $ do
  ctx <- view logContextL
  logError $ formatContext ctx <> msg

logDebugC :: (HasCallStack, HasLogFunc env, HasLogContext env, MonadReader env m, MonadIO m) => Utf8Builder -> m ()
logDebugC msg = withFrozenCallStack $ do
  ctx <- view logContextL
  logDebug $ formatContext ctx <> msg

correlationIdKey :: Vault.Key CorrelationId
correlationIdKey = unsafePerformIO Vault.newKey
{-# NOINLINE correlationIdKey #-}

correlationIdMiddleware :: Middleware
correlationIdMiddleware app req respond = do
  let maybeHeaderCid = lookup "X-Correlation-Id" (requestHeaders req)

  baseCid <- case maybeHeaderCid of
    Just headerVal
      | not (BS.null headerVal) ->
          return $ CorrelationId $ TE.decodeUtf8 headerVal
    _ ->
      generateCorrelationId

  cid <- appendCorrelationId baseCid

  let req' = req {Wai.vault = Vault.insert correlationIdKey cid (Wai.vault req)}

  app req' $ \response -> do
    let cidHeader = ("X-Correlation-Id", TE.encodeUtf8 $ unCorrelationId cid)
    let response' = Wai.mapResponseHeaders (cidHeader :) response
    respond response'

extractCorrelationId :: Request -> Maybe CorrelationId
extractCorrelationId req = Vault.lookup correlationIdKey (vault req)

-- | Log the start and end of every HTTP request.
--
-- Must be placed AFTER 'correlationIdMiddleware' in the chain so the CID is
-- already in the vault:
--
-- > correlationIdMiddleware $ requestLoggingMiddleware lf getPrincipal $ \req -> ...
--
-- The @getPrincipal@ callback returns the authenticated principal (e.g. the
-- JWT subject) to include on the request log line, or 'Nothing' for anonymous
-- requests. Use 'Service.Auth.jwtPrincipalExtractor' for JWT-protected
-- services; pass @(\\_ -> return Nothing)@ for unauthenticated ones.
--
-- Produces two log lines per request:
--
-- > [cid=abc123 ] --> GET /api/accounts (principal=user-42)
-- > [cid=abc123 ] <-- 200 (4ms)
requestLoggingMiddleware :: LogFunc -> (Request -> IO (Maybe Text)) -> Middleware
requestLoggingMiddleware logFunc getPrincipal inner req respond = do
  let method = TE.decodeUtf8 (requestMethod req)
      path = TE.decodeUtf8 (rawPathInfo req)
      cid = maybe "?" unCorrelationId (extractCorrelationId req)
      ctx = Map.fromList [("cid", cid)]
  maybePrincipal <- getPrincipal req
  let principalSuffix = maybe "" (\p -> " (principal=" <> display p <> ")") maybePrincipal
  start <- getCurrentTime
  runRIO logFunc $
    logInfo $ formatContext ctx <> "--> " <> display method <> " " <> display path <> principalSuffix
  inner req $ \response -> do
    end <- getCurrentTime
    let status = statusCode (responseStatus response)
        ms = round (diffUTCTime end start * 1000) :: Int
    runRIO logFunc $
      logInfo $ formatContext ctx <> "<-- " <> displayShow status <> " (" <> displayShow ms <> "ms)"
    respond response
