module Service.Metrics.Http
  ( HttpMetrics (..),
    HasHttpMetrics (..),
    initHttpMetrics,
    metricsMiddleware,
    exportHttpMetrics,
  )
where

import qualified Data.Map.Strict as Map
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Conc (unsafeIOToSTM)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import RIO
import Service.Metrics.Core

-- ============================================================================
-- HTTP Metrics Data Structure
-- ============================================================================

data HttpMetrics = HttpMetrics
  { httpRequestsTotal :: (Map (Text, Text, Text) Counter),
    -- Key: (method, endpoint, status)
    httpRequestDuration :: (Map (Text, Text) Histogram),
    -- Key: (method, endpoint)
    httpActiveRequests :: Gauge,
    httpRequestSize :: (Map (Text, Text) Histogram),
    -- Key: (method, endpoint)
    httpResponseSize :: (Map (Text, Text) Histogram)
    -- Key: (method, endpoint)
  }

class HasHttpMetrics env where
  httpMetricsL :: Lens' env HttpMetrics

-- ============================================================================
-- Initialization
-- ============================================================================

initHttpMetrics :: IO HttpMetrics
initHttpMetrics = do
  httpActiveReqs <- newGauge

  return
    HttpMetrics
      { httpRequestsTotal = Map.empty,
        httpRequestDuration = Map.empty,
        httpActiveRequests = httpActiveReqs,
        httpRequestSize = Map.empty,
        httpResponseSize = Map.empty
      }

-- ============================================================================
-- HTTP Middleware
-- ============================================================================

metricsMiddleware :: TVar HttpMetrics -> Wai.Middleware
metricsMiddleware metricsVar app req respond = do
  let method = TE.decodeUtf8 $ Wai.requestMethod req
      path = TE.decodeUtf8 $ Wai.rawPathInfo req
      normalizedPath = normalizePath path

  -- Increment active requests
  metrics <- readTVarIO metricsVar
  incGauge (httpActiveRequests metrics)

  -- Time the request
  start <- getCurrentTime
  app req $ \response -> do
    end <- getCurrentTime
    let duration = realToFrac $ diffUTCTime end start
        status = T.pack $ show $ HTTP.statusCode $ Wai.responseStatus response

    -- Decrement active requests
    decGauge (httpActiveRequests metrics)

    -- Record metrics atomically
    atomically $ do
      m <- readTVar metricsVar

      -- Record request count
      let reqKey = (method, normalizedPath, status)
      reqCounter <- case Map.lookup reqKey (httpRequestsTotal m) of
        Just c -> return c
        Nothing -> unsafeIOToSTM newCounter
      unsafeIOToSTM $ incCounter reqCounter
      let m1 = m {httpRequestsTotal = Map.insert reqKey reqCounter (httpRequestsTotal m)}

      -- Record request duration
      let durationKey = (method, normalizedPath)
      durationHist <- case Map.lookup durationKey (httpRequestDuration m1) of
        Just h -> return h
        Nothing -> unsafeIOToSTM $ newHistogram defaultBuckets
      unsafeIOToSTM $ observeHistogram durationHist duration
      let m2 = m1 {httpRequestDuration = Map.insert durationKey durationHist (httpRequestDuration m1)}

      writeTVar metricsVar m2

    respond response

-- Normalize path to reduce cardinality (replace numeric IDs with :id)
normalizePath :: Text -> Text
normalizePath path =
  let segments = T.splitOn "/" path
      normalized = map normalizeSegment segments
   in T.intercalate "/" normalized
  where
    normalizeSegment :: Text -> Text
    normalizeSegment seg
      | T.all (\c -> c >= '0' && c <= '9') seg && not (T.null seg) = ":id"
      | otherwise = seg

-- ============================================================================
-- Metrics Export
-- ============================================================================

exportHttpMetrics :: HttpMetrics -> IO [Text]
exportHttpMetrics metrics = do
  -- HTTP request counts
  requestCounts <- forM (Map.toList $ httpRequestsTotal metrics) $ \((method, endpoint, status), Counter tvar) -> do
    count <- readTVarIO tvar
    return $ "http_requests_total{method=\"" <> method <> "\",endpoint=\"" <> endpoint <> "\",status=\"" <> status <> "\"} " <> T.pack (show count)

  -- Active requests
  activeReqs <- readTVarIO $ case httpActiveRequests metrics of Gauge tvar -> tvar
  let activeReqsLine = "http_active_requests " <> T.pack (show activeReqs)

  return $
    ["# HELP http_requests_total Total HTTP requests", "# TYPE http_requests_total counter"]
      <> requestCounts
      <> ["# HELP http_active_requests Currently active HTTP requests", "# TYPE http_active_requests gauge", activeReqsLine]
