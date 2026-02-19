-- | Standalone migration runner for production deployments.
-- Usage: stack exec auth-service-migrations
module Main (main) where

import Control.Monad.Logger (runStderrLoggingT)
import Database.Persist.Sql (runMigration, runSqlPool)
import Models.User (migrateAll)
import RIO
import qualified Service.Database as Database
import System.IO (putStrLn)

main :: IO ()
main = do
  putStrLn "=== Auth Service Migration Runner ==="
  putStrLn "WARNING: Only run this on a single instance!"
  putStrLn ""

  logOptions <- logOptionsHandle stderr False
  withLogFunc logOptions $ \logFunc -> runRIO logFunc $ do
    dbSettings <- Database.decoder

    logInfo $ "Database type: " <> displayShow (Database.dbType dbSettings)
    logInfo "Connecting to database..."

    pool <- liftIO $ Database.createConnectionPool dbSettings

    logInfo "Running migrations..."

    liftIO $ runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool

    logInfo "Migrations completed successfully!"
