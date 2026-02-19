{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
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

module Models.User where

import Data.Time (UTCTime)
import Database.Persist.TH
import RIO

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
User
  email Text
  passwordHash Text
  UniqueEmail email
  deriving Show Generic

RefreshToken
  jti Text
  userId UserId
  expiresAt UTCTime
  revoked Bool default=False
  createdAt UTCTime
  UniqueJti jti
  deriving Show Generic
  |]
