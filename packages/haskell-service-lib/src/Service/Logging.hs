module Service.Logging
  ( withUtcLogFunc,
  )
where

import RIO
import System.Environment (setEnv)

-- | Variant of 'withLogFunc' that forces log timestamps to UTC.
--
-- RIO's logger calls 'getZonedTime' internally, which respects the @TZ@
-- environment variable. Setting @TZ=UTC@ here ensures every log line carries
-- a UTC timestamp regardless of the host's local timezone, which is the
-- correct behaviour for production services (and is required for Promtail /
-- Loki to store entries at the right time).
withUtcLogFunc :: Handle -> Bool -> (LogFunc -> IO a) -> IO a
withUtcLogFunc handle verbose action = do
  setEnv "TZ" "UTC"
  logOptions <- logOptionsHandle handle verbose
  withLogFunc logOptions action
