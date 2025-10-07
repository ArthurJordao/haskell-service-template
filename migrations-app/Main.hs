-- | Standalone migration runner for production deployments
-- Usage: stack exec run-migrations
module Main (main) where

import Control.Monad.Logger (runStderrLoggingT)
import Database.Persist.Sql (runMigration, runSqlPool)
import Database.Persist.Sqlite (createSqlitePool)
import qualified Service.Database as Database
import Models.Account (migrateAll)
import RIO
import System.IO (putStrLn)

main :: IO ()
main = do
  putStrLn "=== Database Migration Runner ==="
  putStrLn "WARNING: Only run this on a single instance!"
  putStrLn ""

  -- Load settings from environment
  logOptions <- logOptionsHandle stderr False
  withLogFunc logOptions $ \logFunc -> runRIO logFunc $ do
    dbSettings <- Database.decoder

    logInfo $ "Database: " <> displayShow (Database.dbPath dbSettings)
    logInfo "Connecting to database..."

    pool <- liftIO $ runStderrLoggingT $
      createSqlitePool
        (Database.dbPath dbSettings)
        1

    logInfo "Running migrations..."

    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

    logInfo "Migrations completed successfully!"
