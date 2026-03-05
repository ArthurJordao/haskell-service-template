module Service.Redis
  ( HasRedis (..),
    makeRedisConnection,
    isJtiRevoked,
    isUserInvalidated,
    revokeJti,
    invalidateUserTokens,
    makeRevocationCheck,
  )
where

import qualified Database.Redis as Redis
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import RIO
import RIO.Text (pack, unpack)
import Service.Auth (AccessTokenClaims (..))

class HasRedis env where
  getRedisConnection :: env -> Redis.Connection

-- | Parse a Redis URL (redis://host:port) and open a connection.
makeRedisConnection :: String -> IO Redis.Connection
makeRedisConnection url = Redis.connect (parseRedisUrl url)

parseRedisUrl :: String -> Redis.ConnectInfo
parseRedisUrl url
  | take 8 url == "redis://" =
      let rest = drop 8 url
          (hostPort, _) = break (== '/') rest
          (host, portStr) = break (== ':') hostPort
          port = case readMaybe (drop 1 portStr) :: Maybe Int of
            Just p -> p
            _ -> 6379
       in Redis.defaultConnectInfo
            { Redis.connectHost = if null host then "localhost" else host,
              Redis.connectPort = Redis.PortNumber (fromIntegral port)
            }
  | otherwise = Redis.defaultConnectInfo

-- ============================================================================
-- RIO wrappers
-- ============================================================================

-- | Check whether a JTI is in the Redis denylist.
isJtiRevoked :: HasRedis env => Text -> RIO env Bool
isJtiRevoked jti = do
  conn <- asks getRedisConnection
  liftIO $ checkJtiRevoked conn jti

-- | Check whether a user's token (by issuedAt) has been invalidated.
isUserInvalidated :: HasRedis env => Text -> UTCTime -> RIO env Bool
isUserInvalidated userId issuedAt = do
  conn <- asks getRedisConnection
  liftIO $ checkUserInvalidated conn userId issuedAt

-- | Add a JTI to the denylist with the given TTL in seconds.
revokeJti :: HasRedis env => Text -> Int -> RIO env ()
revokeJti jti ttlSeconds = do
  conn <- asks getRedisConnection
  liftIO $ setJtiRevoked conn jti ttlSeconds

-- | Record a per-user invalidation timestamp (now) so all tokens issued
-- before this moment are rejected on next validation.
invalidateUserTokens :: HasRedis env => Text -> RIO env ()
invalidateUserTokens userId = do
  conn <- asks getRedisConnection
  liftIO $ setUserInvalidationTs conn userId

-- | Build a revocation-check callback suitable for 'JWTAuthConfig'.
-- Returns 'Left' if the token is revoked (JTI denylist or invalidation ts).
makeRevocationCheck :: Redis.Connection -> AccessTokenClaims -> IO (Either Text ())
makeRevocationCheck conn claims = do
  jtiRevoked <- checkJtiRevoked conn (atcJti claims)
  if jtiRevoked
    then return (Left "Token has been revoked")
    else do
      userRevoked <- checkUserInvalidated conn (atcSubject claims) (atcIssuedAt claims)
      if userRevoked
        then return (Left "Token invalidated due to scope change")
        else return (Right ())

-- ============================================================================
-- Low-level IO operations (no typeclass constraint)
-- ============================================================================

checkJtiRevoked :: Redis.Connection -> Text -> IO Bool
checkJtiRevoked conn jti = do
  result <- Redis.runRedis conn $
    Redis.exists (encodeUtf8 ("jti:" <> jti))
  return $ case result of
    Right b -> b
    Left _ -> False

checkUserInvalidated :: Redis.Connection -> Text -> UTCTime -> IO Bool
checkUserInvalidated conn userId issuedAt = do
  result <- Redis.runRedis conn $
    Redis.get (encodeUtf8 ("user:" <> userId <> ":invalidate_before"))
  case result of
    Right (Just tsBytes) ->
      case readMaybe (unpack (decodeUtf8Lenient tsBytes)) :: Maybe Integer of
        Just ts ->
          return $ issuedAt < posixSecondsToUTCTime (fromIntegral ts)
        Nothing -> return False
    _ -> return False

setJtiRevoked :: Redis.Connection -> Text -> Int -> IO ()
setJtiRevoked conn jti ttlSeconds = do
  _ <- Redis.runRedis conn $
    Redis.setex (encodeUtf8 ("jti:" <> jti)) (fromIntegral ttlSeconds) "1"
  return ()

setUserInvalidationTs :: Redis.Connection -> Text -> IO ()
setUserInvalidationTs conn userId = do
  now <- getCurrentTime
  let ts = floor (utcTimeToPOSIXSeconds now) :: Integer
  _ <- Redis.runRedis conn $
    Redis.set
      (encodeUtf8 ("user:" <> userId <> ":invalidate_before"))
      (encodeUtf8 (pack (show ts)))
  return ()
