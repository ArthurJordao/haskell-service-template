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

module Models.DeadLetter where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time.Clock (UTCTime)
import Database.Persist.TH
import RIO

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
DeadLetter
  originalTopic Text
  originalMessage Text
  originalHeaders Text
  errorType Text
  errorDetails Text
  correlationId Text
  createdAt UTCTime
  retryCount Int
  status Text default='pending'
  replayedAt UTCTime Maybe
  replayedBy Text Maybe
  replayResult Text Maybe
  deriving Show Generic ToJSON FromJSON
  |]
