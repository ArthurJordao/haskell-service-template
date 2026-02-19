{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( Repo,
    findDeadLetters,
    findById,
    findAll,
    storeDeadLetter,
    markReplayed,
    markReplayFailed,
    markDiscarded,
  )
where

import Data.Time.Clock (UTCTime)
import Database.Persist.Sql
  ( Entity,
    SelectOpt (..),
    entityVal,
    get,
    insert,
    selectList,
    toSqlKey,
    update,
    (=.),
    (==.),
  )
import Models.DeadLetter
  ( DeadLetter,
    DeadLetterId,
    EntityField (..),
  )
import RIO
import Service.CorrelationId (HasLogContext (..))
import Service.Database (HasDB (..), runSqlPoolWithCid)

type Repo env = (HasLogFunc env, HasLogContext env, HasDB env)

-- | Find dead letters with optional status/topic/errorType filters.
findDeadLetters ::
  Repo env =>
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  RIO env [Entity DeadLetter]
findDeadLetters maybeStatus maybeTopic maybeErrorType = do
  pool <- view dbL
  let filters =
        catMaybes
          [ (DeadLetterStatus ==.) <$> maybeStatus,
            (DeadLetterOriginalTopic ==.) <$> maybeTopic,
            (DeadLetterErrorType ==.) <$> maybeErrorType
          ]
  runSqlPoolWithCid (selectList filters [Desc DeadLetterCreatedAt]) pool

-- | Find a dead letter by numeric ID.
findById :: Repo env => Int64 -> RIO env (Maybe DeadLetter)
findById dlqId = do
  pool <- view dbL
  runSqlPoolWithCid (get (toSqlKey dlqId :: DeadLetterId)) pool

-- | Fetch all dead letters (used for stats).
findAll :: Repo env => RIO env [DeadLetter]
findAll = do
  pool <- view dbL
  entities <- runSqlPoolWithCid (selectList [] []) pool
  return $ map entityVal entities

-- | Persist a new dead letter record.
storeDeadLetter :: Repo env => DeadLetter -> RIO env DeadLetterId
storeDeadLetter dl = do
  pool <- view dbL
  runSqlPoolWithCid (insert dl) pool

-- | Mark a dead letter as successfully replayed.
markReplayed :: Repo env => DeadLetterId -> UTCTime -> RIO env ()
markReplayed key now = do
  pool <- view dbL
  runSqlPoolWithCid
    ( update
        key
        [ DeadLetterStatus =. "replayed",
          DeadLetterReplayedAt =. Just now,
          DeadLetterReplayResult =. Just "success"
        ]
    )
    pool

-- | Record a replay failure without changing status.
markReplayFailed :: Repo env => DeadLetterId -> Text -> UTCTime -> RIO env ()
markReplayFailed key errMsg now = do
  pool <- view dbL
  runSqlPoolWithCid
    ( update
        key
        [ DeadLetterReplayResult =. Just errMsg,
          DeadLetterReplayedAt =. Just now
        ]
    )
    pool

-- | Mark a dead letter as discarded.
markDiscarded :: Repo env => DeadLetterId -> UTCTime -> RIO env ()
markDiscarded key now = do
  pool <- view dbL
  runSqlPoolWithCid
    ( update
        key
        [ DeadLetterStatus =. "discarded",
          DeadLetterReplayedAt =. Just now
        ]
    )
    pool
