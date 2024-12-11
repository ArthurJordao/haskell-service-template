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
server = do
  logInfo "Api called"
  return "Hello, world!"

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
