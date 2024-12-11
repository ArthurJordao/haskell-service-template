{-# LANGUAGE DataKinds #-}

module Server (startApp) where

import API
import Network.Wai.Handler.Warp (run)
import RIO
import Servant

data App = App
  { appLogFunc :: !LogFunc
  }

type AppM = RIO App

server :: ServerT API AppM
server = return "Hello, world!"

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
