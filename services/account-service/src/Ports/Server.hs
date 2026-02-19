module Ports.Server
  ( API,
    Routes (..),
    Account (..),
    CreateAccountRequest (..),
    AccountCreatedEvent (..),
    ExternalPost (..),
    server,
    HasConfig (..),
    module Service.Server,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Database.Persist.Sql (Entity (..), entityVal, fromSqlKey, get, insert, selectList, toSqlKey)
import Kafka.Consumer (TopicName (..))
import Models.Account (Account (..), AccountId)
import RIO
import RIO.Text (pack)
import Servant
import Servant.Server.Generic (AsServerT)
import Service.CorrelationId (HasCorrelationId (..), HasLogContext (..), logInfoC)
import Service.Database (HasDB (..), runSqlPoolWithCid)
import Service.Metrics.Optional (OptionalDatabaseMetrics)
import Service.Kafka (HasKafkaProducer (..))
import Service.Auth (AccessTokenClaims (..), RequireOwner)
import Service.HttpClient (HasHttpClient, callServiceGet)
import Service.Metrics (HasMetrics (..), metricsHandler)
import Service.Server

-- ============================================================================
-- API Types
-- ============================================================================

data CreateAccountRequest = CreateAccountRequest
  { createAccountName :: !Text,
    createAccountEmail :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ExternalPost = ExternalPost
  { userId :: !Int,
    id :: !Int,
    title :: !Text,
    body :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AccountCreatedEvent = AccountCreatedEvent
  { eventAccountId :: !Int,
    eventAccountName :: !Text,
    eventAccountEmail :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Routes route = Routes
  { status ::
      route
        :- Summary "Health check endpoint"
          :> "status"
          :> Get '[JSON] Text,
    getAccounts ::
      route
        :- Summary "Get all accounts"
          :> "accounts"
          :> Get '[JSON] [Account],
    getAccountById ::
      route
        :- Summary "Get account by ID"
          :> "accounts"
          :> RequireOwner "id" Int64
          :> Get '[JSON] Account,
    createAccount ::
      route
        :- Summary "Create a new account"
          :> "accounts"
          :> ReqBody '[JSON] CreateAccountRequest
          :> Post '[JSON] Account,
    getExternalPost ::
      route
        :- Summary "Example: Fetch external post via HTTP client"
          :> "external"
          :> "posts"
          :> Capture "id" Int
          :> Get '[JSON] ExternalPost,
    getMetrics ::
      route
        :- Summary "Prometheus metrics endpoint"
          :> "metrics"
          :> Get '[PlainText] Text
  }
  deriving stock (Generic)

type API = NamedRoutes Routes

-- ============================================================================
-- Server Implementation
-- ============================================================================

server :: (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasConfig env settings, HasDB env, HasKafkaProducer env, HasHttpClient env, HasMetrics env, OptionalDatabaseMetrics env) => Routes (AsServerT (RIO env))
server =
  Routes
    { status = statusHandler,
      getAccounts = accountsHandler,
      getAccountById = accountByIdHandler,
      createAccount = createAccountHandler,
      getExternalPost = externalPostHandler,
      getMetrics = metricsEndpointHandler
    }

statusHandler :: forall env settings. (HasLogFunc env, HasLogContext env, HasConfig env settings) => RIO env Text
statusHandler = do
  settings <- view (settingsL @env @settings)
  let serverSettings = httpSettings @env @settings settings
  logInfoC ("Status endpoint called env level" <> displayShow (httpEnvironment serverSettings))
  return "OK"

accountsHandler :: (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) => RIO env [Account]
accountsHandler = do
  logInfoC "Accounts endpoint called"
  pool <- view dbL
  accounts <- runSqlPoolWithCid (selectList [] []) pool
  return $ map entityVal accounts

accountByIdHandler :: (HasLogFunc env, HasLogContext env, HasDB env, OptionalDatabaseMetrics env) => Int64 -> AccessTokenClaims -> RIO env Account
accountByIdHandler accId _claims = do
  logInfoC $ "Account endpoint called with ID: " <> displayShow accId
  pool <- view dbL
  maybeAccount <- runSqlPoolWithCid (get (toSqlKey accId :: AccountId)) pool
  case maybeAccount of
    Just account -> return account
    Nothing -> throwM err404 {errBody = "Account not found"}

createAccountHandler :: (HasLogFunc env, HasLogContext env, HasDB env, HasKafkaProducer env, OptionalDatabaseMetrics env) => CreateAccountRequest -> RIO env Account
createAccountHandler req = do
  logInfoC $ "Creating account: " <> displayShow (createAccountName req)
  pool <- view dbL

  let newAccount =
        Account
          { accountName = createAccountName req,
            accountEmail = createAccountEmail req
          }

  accountId <- runSqlPoolWithCid (insert newAccount) pool
  let accountIdInt :: Int
      accountIdInt = fromIntegral $ fromSqlKey accountId

  let event =
        AccountCreatedEvent
          { eventAccountId = accountIdInt,
            eventAccountName = createAccountName req,
            eventAccountEmail = createAccountEmail req
          }

  produceKafkaMessage (TopicName "account-created") Nothing event
  logInfoC $ "Published account-created event for account ID: " <> displayShow accountIdInt

  return newAccount

externalPostHandler :: (HasLogFunc env, HasLogContext env, HasCorrelationId env, HasHttpClient env) => Int -> RIO env ExternalPost
externalPostHandler postId = do
  logInfoC $ "Fetching external post with ID: " <> displayShow postId
  let url = "https://jsonplaceholder.typicode.com/posts/" <> pack (show postId)
  result <- callServiceGet url []
  case result of
    Left err -> do
      logInfoC $ "Failed to fetch external post: " <> displayShow err
      throwM err500 {errBody = "Failed to fetch external post"}
    Right post -> do
      logInfoC $ "Successfully fetched external post: " <> displayShow (title post)
      return post

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics

class HasConfig env settings | env -> settings where
  settingsL :: Lens' env settings
  httpSettings :: settings -> Settings
