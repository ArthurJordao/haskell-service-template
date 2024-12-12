module Lib (
  app,
)
where

import RIO
import Server (startApp)

app :: IO ()
app = startApp
