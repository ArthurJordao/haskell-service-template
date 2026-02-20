module Lib
  ( app,
  )
where

import qualified App
import RIO
import Service.Logging (withUtcLogFunc)
import Settings (loadSettings)

app :: IO ()
app = do
  withUtcLogFunc stderr True $ \logFunc -> do
    settings <- loadSettings logFunc
    appEnv <- App.initializeApp settings logFunc
    App.runApp appEnv
