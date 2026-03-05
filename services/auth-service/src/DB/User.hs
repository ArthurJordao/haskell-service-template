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
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module DB.User where

import Data.Time (Day (..), UTCTime (..))
import Database.Persist.TH
import RIO
import Service.Persist (deriveEntityMeta, persistWithMeta)

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistWithMeta|
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
  UniqueJti jti
  deriving Show Generic

Scope
  name        Text
  description Text
  UniqueScope name
  deriving Show Generic

UserScope
  userId    UserId
  scope     Text
  grantedBy UserId Maybe
  UniqueUserScope userId scope
  deriving Show Generic
  |]

$(deriveEntityMeta ''User)
$(deriveEntityMeta ''RefreshToken)
$(deriveEntityMeta ''Scope)
$(deriveEntityMeta ''UserScope)
