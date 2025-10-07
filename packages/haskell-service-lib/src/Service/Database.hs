module Service.Database (
  HasDB (..),
  runSqlPoolWithCid,
  Settings (..),
  decoder,
) where

import Control.Monad.Logger (LoggingT (..), runLoggingT)
import qualified Data.Map.Strict as Map
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Database.Persist.Sql (SqlBackend)
import Database.Persist.SqlBackend.Internal (connLogFunc)
import Database.Persist.Sqlite (ConnectionPool)
import Data.Pool (withResource)
import RIO
import RIO.Text (pack)
import Service.CorrelationId (HasLogContext (..))
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))
import System.Log.FastLogger (fromLogStr)

data Settings = Settings
  { dbPath :: !Text,
    dbPoolSize :: !Int,
    dbAutoMigrate :: !Bool
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ =
    Settings
      <$> (pack <$> (env "DB_PATH" .!= "accounts.db"))
      <*> (env "DB_POOL_SIZE" .!= 10)
      <*> (env "DB_AUTO_MIGRATE" .!= True)

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO $ decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode database settings, using defaults: " <> displayShow err
      return $ Settings (pack "accounts.db") 10 True
    Right settings -> return settings

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
