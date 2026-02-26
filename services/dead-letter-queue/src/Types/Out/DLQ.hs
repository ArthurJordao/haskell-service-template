{-# LANGUAGE DuplicateRecordFields #-}

module Types.Out.DLQ
  ( DeadLetterResponse (..),
    ReplayResult (..),
    DLQStats (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time.Clock (UTCTime)
import RIO

data DeadLetterResponse = DeadLetterResponse
  { id :: Int64,
    originalTopic :: Text,
    originalMessage :: Text,
    originalHeaders :: Text,
    errorType :: Text,
    errorDetails :: Text,
    correlationId :: Text,
    createdAt :: UTCTime,
    retryCount :: Int,
    status :: Text,
    replayedAt :: (Maybe UTCTime),
    replayedBy :: (Maybe Text),
    replayResult :: (Maybe Text)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ReplayResult = ReplayResult
  { id :: Int64,
    success :: Bool,
    message :: (Maybe Text)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data DLQStats = DLQStats
  { total :: Int,
    pending :: Int,
    replayed :: Int,
    discarded :: Int,
    byErrorType :: (Map Text Int)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
