{-# LANGUAGE DataKinds #-}

module Server (startApp) where

import API
import qualified Data.Maybe
import Network.Wai.Handler.Warp (run)
import RIO
import RIO.Text (pack)
import Servant
import System.Environment.Blank (getEnvDefault)

data Config = Config
  { port :: Int
  , environment :: Text
  }

data App = App
  { appLogFunc :: !LogFunc
  , config :: !Config
  }

instance HasLogFunc App where
  logFuncL = lens appLogFunc (\x y -> x{appLogFunc = y})

class HasConfig env where
  envVariablesL :: Lens' env Config

instance HasConfig App where
  envVariablesL = lens config (\x y -> x{config = y})

server :: ServerT API (RIO App)
server =
  statusHandler
    :<|> accountsHandler
    :<|> accountByIdHandler

accounts :: [Account]
accounts = [Account 1 "Alice", Account 2 "Bob"]

statusHandler :: (HasLogFunc a, HasConfig a) => RIO a Text
statusHandler = do
  env <- view envVariablesL
  logInfo ("Status endpoint called env level" <> displayShow (environment env))
  return "OK"

accountsHandler :: (HasLogFunc a) => RIO a [Account]
accountsHandler = do
  logInfo "Accounts endpoint called"
  return accounts

accountByIdHandler :: (HasLogFunc a) => Int -> RIO a Account
accountByIdHandler accId = do
  logInfo $ "Account endpoint called with ID: " <> displayShow accId
  let account = filter (\acc -> accountId acc == accId) accounts
  case account of
    [acc] -> return acc
    _ -> throwM err404{errBody = "Account not found"}

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
  withLogFunc logOptions $ \logFunc -> do
    let env =
          App
            { appLogFunc = logFunc
            , config =
                Config
                  { port = Data.Maybe.fromMaybe 8080 (readMaybe portStr :: Maybe Int)
                  , environment = pack environment'
                  }
            }
    run (port $ config env) (app env)
