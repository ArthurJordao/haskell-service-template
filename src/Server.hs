{-# LANGUAGE DataKinds #-}

module Server (startApp) where

import API
import Network.Wai.Handler.Warp (run)
import RIO
import Servant

data App = App
  { appLogFunc :: !LogFunc
  }

instance HasLogFunc App where
  logFuncL = lens appLogFunc (\x y -> x {appLogFunc = y})

server :: ServerT API (RIO App)
server =
  statusHandler
    :<|> accountsHandler
    :<|> accountByIdHandler

accounts :: [Account]
accounts = [Account 1 "Alice", Account 2 "Bob"]

statusHandler :: (HasLogFunc a) => RIO a Text
statusHandler = do
  logInfo "Status endpoint called"
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
    _ -> throwM err404 {errBody = "Account not found"}

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
  withLogFunc logOptions $ \logFunc -> do
    let env = App {appLogFunc = logFunc}
    run 8080 (app env)
