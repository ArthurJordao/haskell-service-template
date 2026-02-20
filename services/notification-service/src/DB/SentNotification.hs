{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module DB.SentNotification where

import Data.Time.Clock (UTCTime)
import Database.Persist.TH
import RIO (Show, Text)

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
SentNotification
  templateName Text
  channelType  Text
  recipient    Text
  content      Text
  sentAt       UTCTime
  deriving Show
  |]
