{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module DB.SentNotification where

import Data.Time (UTCTime (..))
import Database.Persist.TH
import RIO (Show, Text)
import Service.Persist (deriveEntityMeta, persistWithMeta)

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistWithMeta|
SentNotification
  templateName Text
  channelType  Text
  recipient    Text
  content      Text
  deriving Show
  |]

$(deriveEntityMeta ''SentNotification)
