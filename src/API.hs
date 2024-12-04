{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
module API where

import RIO
import Servant

type API = "hello" :> Get '[PlainText] Text
