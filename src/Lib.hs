module Lib
  ( someFunc,
  )
where

import RIO

someFunc :: IO ()
someFunc = runSimpleApp $ logInfo "someFunc"
