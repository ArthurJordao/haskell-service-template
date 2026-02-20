{-# LANGUAGE ConstraintKinds #-}

module Ports.Repository
  ( getNotificationsByRecipient,
  )
where

import DB.SentNotification (EntityField (..), SentNotification)
import Database.Persist.Sql (Entity, selectList, (==.))
import RIO
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Service.CorrelationId (HasLogContext (..))

type Repo env = (HasDB env, HasLogContext env, HasLogFunc env)

getNotificationsByRecipient ::
  (Repo env) =>
  Text ->
  RIO env [Entity SentNotification]
getNotificationsByRecipient recipient = do
  pool <- view dbL
  runSqlPoolWithCid (selectList [SentNotificationRecipient ==. recipient] []) pool
