module Lib
  ( app,
  )
where

import qualified App
import RIO
import Settings (loadSettings)

app :: IO ()
app = do
  logOptions <- logOptionsHandle stderr True
  withLogFunc logOptions $ \logFunc -> do
    settings <- loadSettings logFunc
    appEnv <- App.initializeApp settings logFunc
    App.runApp appEnv
