module Server (startApp) where

import RIO
import Servant
import Network.Wai.Handler.Warp (run)
import API

server :: Server API
server = return "Hello, world!"

api :: Proxy API
api = Proxy

app :: Application
app = serve api server

startApp :: IO ()
startApp = run 8080 app
