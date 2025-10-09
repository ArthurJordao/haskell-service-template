{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Models.Account (Account (..), migrateAll, AccountId) where

import Data.Aeson (FromJSON, ToJSON)
import Database.Persist.TH
import RIO

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
Account
  name Text
  email Text
  deriving Show Generic ToJSON FromJSON
  |]
