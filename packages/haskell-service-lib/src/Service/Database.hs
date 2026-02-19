module Service.Database
  ( HasDB (..),
    runSqlPoolWithCid,
    Settings (..),
    DatabaseType (..),
    decoder,
    createConnectionPool,
  )
where

import Control.Monad.Logger (LoggingT (..), runLoggingT, runStderrLoggingT)
import qualified Data.Map.Strict as Map
import Data.Pool (withResource)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Database.Persist.Postgresql (createPostgresqlPool)
import Database.Persist.Sql (ConnectionPool, SqlBackend)
import Database.Persist.SqlBackend.Internal (connLogFunc)
import Database.Persist.Sqlite (createSqlitePool)
import Data.Time.Clock (UTCTime, getCurrentTime)
import RIO
import RIO.Text (pack, toLower)
import Service.CorrelationId (HasLogContext (..))
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))
import System.Log.FastLogger (fromLogStr)

data DatabaseType = SQLite | PostgreSQL
  deriving (Show, Eq)

data Settings = Settings
  { dbType :: !DatabaseType,
    dbConnectionString :: !Text,
    dbPoolSize :: !Int,
    dbAutoMigrate :: !Bool
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ = do
    dbTypeStr <- pack <$> (env "DB_TYPE" .!= "sqlite")
    let dbType' = case toLower dbTypeStr of
          "postgresql" -> PostgreSQL
          "postgres" -> PostgreSQL
          _ -> SQLite

    connectionString <- pack <$> case dbType' of
      SQLite -> env "DB_CONNECTION_STRING" .!= "accounts.db"
      PostgreSQL -> env "DB_CONNECTION_STRING" .!= "host=localhost port=5432 user=postgres dbname=accounts password=postgres"

    poolSize <- env "DB_POOL_SIZE" .!= 10
    autoMigrateStr <- pack <$> (env "DB_AUTO_MIGRATE" .!= "true")
    let autoMigrate = toLower autoMigrateStr `elem` ["true", "1", "yes"]
    return $ Settings dbType' connectionString poolSize autoMigrate

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO $ decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode database settings, using defaults: " <> displayShow err
      return $ Settings SQLite (pack "accounts.db") 10 True
    Right settings -> return settings

createConnectionPool :: Settings -> IO ConnectionPool
createConnectionPool settings =
  runStderrLoggingT $ case settings.dbType of
    SQLite -> createSqlitePool settings.dbConnectionString settings.dbPoolSize
    PostgreSQL -> createPostgresqlPool (TE.encodeUtf8 settings.dbConnectionString) settings.dbPoolSize

-- | Type class for environments that carry a database connection pool.
-- Override 'dbRecordQueryMetrics' to instrument queries with timing metrics;
-- the default implementation is a no-op.
class HasDB env where
  dbL :: Lens' env ConnectionPool
  dbRecordQueryMetrics :: Text -> UTCTime -> UTCTime -> Either SomeException a -> RIO env ()
  dbRecordQueryMetrics _ _ _ _ = return ()

runSqlPoolWithCid ::
  forall env m a.
  (HasLogFunc env, HasLogContext env, HasDB env, MonadUnliftIO m, MonadReader env m) =>
  ReaderT SqlBackend (LoggingT m) a ->
  ConnectionPool ->
  m a
runSqlPoolWithCid action pool = do
  ctx <- view logContextL
  let cidPrefix = case Map.lookup "cid" ctx of
        Just cid -> "[cid=" <> cid <> "] "
        Nothing -> ""

  start <- liftIO getCurrentTime
  result <- tryAny $ withRunInIO $ \runInIO ->
    withResource pool $ \backend -> do
      let wrappedLogFunc _loc _source _level msg = do
            let msgText = TE.decodeUtf8With TE.lenientDecode (fromLogStr msg)
                prefixedMsg = cidPrefix <> msgText
            runInIO $ logInfo $ display prefixedMsg

      let modifiedBackend = backend {connLogFunc = wrappedLogFunc}

      runInIO $ runLoggingT (runReaderT action modifiedBackend) $ \_ _ _ _ ->
        pure ()

  end <- liftIO getCurrentTime

  environment <- ask
  liftIO $ runRIO environment $ dbRecordQueryMetrics "query" start end result

  case result of
    Left err -> throwIO err
    Right val -> return val
