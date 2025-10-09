module Service.Database (
  HasDB (..),
  runSqlPoolWithCid,
  Settings (..),
  DatabaseType (..),
  decoder,
  createConnectionPool,
) where

import Control.Monad.Logger (LoggingT (..), runLoggingT, runStderrLoggingT)
import qualified Data.Map.Strict as Map
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Database.Persist.Sql (SqlBackend, ConnectionPool)
import Database.Persist.SqlBackend.Internal (connLogFunc)
import Database.Persist.Sqlite (createSqlitePool)
import Database.Persist.Postgresql (createPostgresqlPool)
import Data.Pool (withResource)
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
    dbTypeStr <- pack <$> env "DB_TYPE" .!= "sqlite"
    let dbType' = case toLower dbTypeStr of
          "postgresql" -> PostgreSQL
          "postgres" -> PostgreSQL
          _ -> SQLite

    connectionString <- pack <$> case dbType' of
      SQLite -> env "DB_CONNECTION_STRING" .!= "accounts.db"
      PostgreSQL -> env "DB_CONNECTION_STRING" .!= "host=localhost port=5432 user=postgres dbname=accounts password=postgres"

    Settings dbType' connectionString
      <$> (env "DB_POOL_SIZE" .!= 10)
      <*> (env "DB_AUTO_MIGRATE" .!= True)

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
    PostgreSQL -> createPostgresqlPool (encodeUtf8 settings.dbConnectionString) settings.dbPoolSize

class HasDB env where
  dbL :: Lens' env ConnectionPool

runSqlPoolWithCid ::
  (HasLogFunc env, HasLogContext env, MonadUnliftIO m, MonadReader env m) =>
  ReaderT SqlBackend (LoggingT m) a ->
  ConnectionPool ->
  m a
runSqlPoolWithCid action pool = do
  ctx <- view logContextL
  let cidPrefix = case Map.lookup "cid" ctx of
        Just cid -> "[cid=" <> cid <> "] "
        Nothing -> ""

  withRunInIO $ \runInIO ->
    withResource pool $ \backend -> do
      let wrappedLogFunc loc source level msg = do
            let msgText = decodeUtf8With lenientDecode (fromLogStr msg)
                prefixedMsg = cidPrefix <> msgText
            runInIO $ logInfo $ display prefixedMsg

      let modifiedBackend = backend { connLogFunc = wrappedLogFunc }

      runInIO $ runLoggingT (runReaderT action modifiedBackend) $ \_ _ _ _ ->
        pure ()
