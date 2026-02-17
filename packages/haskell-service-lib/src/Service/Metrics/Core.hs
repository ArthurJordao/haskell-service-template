module Service.Metrics.Core
  ( Counter (..),
    Gauge (..),
    Histogram (..),
    HistogramBucket (..),
    incCounter,
    setGauge,
    incGauge,
    decGauge,
    observeHistogram,
    newCounter,
    newGauge,
    newHistogram,
    defaultBuckets,
  )
where

import RIO

-- ============================================================================
-- Basic Metric Types (in-memory, STM-based)
-- ============================================================================

newtype Counter = Counter (TVar Double)

newtype Gauge = Gauge (TVar Double)

data HistogramBucket = HistogramBucket
  { bucketUpperBound :: !Double,
    bucketCount :: !(TVar Int)
  }

data Histogram = Histogram
  { histogramSum :: !(TVar Double),
    histogramCount :: !(TVar Int),
    histogramBuckets :: ![HistogramBucket]
  }

-- ============================================================================
-- Metric Operations
-- ============================================================================

incCounter :: Counter -> IO ()
incCounter (Counter tvar) = atomically $ modifyTVar' tvar (+ 1)

setGauge :: Gauge -> Double -> IO ()
setGauge (Gauge tvar) val = atomically $ writeTVar tvar val

incGauge :: Gauge -> IO ()
incGauge (Gauge tvar) = atomically $ modifyTVar' tvar (+ 1)

decGauge :: Gauge -> IO ()
decGauge (Gauge tvar) = atomically $ modifyTVar' tvar (\x -> x - 1)

observeHistogram :: Histogram -> Double -> IO ()
observeHistogram hist val = atomically $ do
  modifyTVar' (histogramSum hist) (+ val)
  modifyTVar' (histogramCount hist) (+ 1)
  forM_ (histogramBuckets hist) $ \bucket ->
    when (val <= bucketUpperBound bucket) $
      modifyTVar' (bucketCount bucket) (+ 1)

newCounter :: IO Counter
newCounter = Counter <$> newTVarIO 0

newGauge :: IO Gauge
newGauge = Gauge <$> newTVarIO 0

newHistogram :: [Double] -> IO Histogram
newHistogram buckets = do
  sum' <- newTVarIO 0
  count' <- newTVarIO 0
  buckets' <- forM buckets $ \bound -> do
    count <- newTVarIO 0
    return $ HistogramBucket bound count
  return $ Histogram sum' count' buckets'

defaultBuckets :: [Double]
defaultBuckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
