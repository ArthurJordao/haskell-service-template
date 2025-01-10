module Server (startApp, Config (..), App (..), app) where

import API
import Control.Monad.Logger (runStderrLoggingT)
import qualified Data.Maybe
import Database.Persist.Sql (entityVal, get, runMigration, selectList, toSqlKey)
import Database.Persist.Sqlite (ConnectionPool, createSqlitePool, runSqlPool)
import Models.Account (AccountId, migrateAll)
import Network.Wai.Handler.Warp (run)
import RIO
import RIO.Text (pack)
import Servant
import System.Environment.Blank (getEnvDefault)

data Config = Config
  { port :: Int,
    environment :: Text
  }

data App = App
  { appLogFunc :: !LogFunc,
    config :: !Config,
    db :: ConnectionPool
  }

instance HasLogFunc App where
  logFuncL = lens appLogFunc (\x y -> x {appLogFunc = y})

class HasConfig env where
  envVariablesL :: Lens' env Config

instance HasConfig App where
  envVariablesL = lens config (\x y -> x {config = y})

class HasDB env where
  dbL :: Lens' env ConnectionPool

instance HasDB App where
  dbL = lens db (\x y -> x {db = y})

server :: ServerT API (RIO App)
server =
  statusHandler
    :<|> accountsHandler
    :<|> accountByIdHandler

statusHandler :: (HasLogFunc a, HasConfig a) => RIO a Text
statusHandler = do
  env <- view envVariablesL
  logInfo ("Status endpoint called env level" <> displayShow (environment env))
  return "OK"

accountsHandler :: (HasLogFunc a, HasDB a) => RIO a [Account]
accountsHandler = do
  logInfo "Accounts endpoint called"
  pool <- view dbL
  accounts <- liftIO $ runSqlPool (selectList [] []) pool
  return $ map entityVal accounts

accountByIdHandler :: (HasLogFunc a, HasDB a) => Int -> RIO a Account
accountByIdHandler accId = do
  logInfo $ "Account endpoint called with ID: " <> displayShow accId
  pool <- view dbL
  maybeAccount <- liftIO $ runSqlPool (get (toSqlKey (fromIntegral accId) :: AccountId)) pool
  case maybeAccount of
    Just account -> return account
    Nothing -> throwM err404 {errBody = "Account not found"}

api :: Proxy API
api = Proxy

type AppContext = '[App]

appContext :: App -> Context AppContext
appContext env = env :. EmptyContext

app :: App -> Application
app env = serveWithContext api (appContext env) (hoistServerWithContext api (Proxy :: Proxy AppContext) (runRIO env) server)

startApp :: IO ()
startApp = do
  logOptions <- logOptionsHandle stderr True
  portStr <- getEnvDefault "PORT" "8080"
  environment' <- getEnvDefault "ENVIRONMENT" "development"
  pool <- runStderrLoggingT $ createSqlitePool "accounts.db" 10
  runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
  withLogFunc logOptions $ \logFunc -> do
    let env =
          App
            { appLogFunc = logFunc,
              config =
                Config
                  { port = Data.Maybe.fromMaybe 8080 (readMaybe portStr :: Maybe Int),
                    environment = pack environment'
                  },
              db = pool
            }
    run (port $ config env) (app env)
