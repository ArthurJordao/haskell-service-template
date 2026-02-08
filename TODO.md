# TODO - Future Ideas

## Authentication & Authorization Service

Implement centralized authentication service with distributed token validation and revocation.

**Goals:**
- JWT-based authentication with user info and scopes
- Distributed token validation across all services
- Token revocation with immediate propagation
- Fine-grained authorization (owner checks, scope-based access)
- Servant helpers for declarative endpoint security

**Architecture:**

1. **Auth Service Responsibilities:**
   - Issue JWT tokens (access + refresh tokens)
   - Store user credentials and permissions
   - Manage scopes and roles
   - Handle token revocation (blacklist)
   - OAuth2/OIDC scope approval flows
   - Publish token revocation events to Kafka

2. **JWT Token Structure (Multiple Token Types):**

   **Customer Token:**
   ```json
   {
     "sub": "user-123",
     "type": "customer",
     "email": "user@example.com",
     "scopes": ["read:accounts:own", "write:accounts:own"],
     "iat": 1234567890,
     "exp": 1234571490,         // Short expiry (15 min)
     "jti": "token-unique-id"
   }
   ```

   **Admin Token:**
   ```json
   {
     "sub": "admin-456",
     "type": "admin",
     "email": "admin@company.com",
     "scopes": ["admin", "read:*", "write:*"],
     "roles": ["support", "finance"],
     "iat": 1234567890,
     "exp": 1234571490,         // Short expiry (15 min)
     "jti": "token-unique-id"
   }
   ```

   **Service Token (Service-to-Service):**
   ```json
   {
     "sub": "service:account-service",
     "type": "service",
     "service_name": "account-service",
     "scopes": ["read:users", "write:notifications"],
     "iat": 1234567890,
     "exp": 1234657890,         // Longer expiry (24h)
     "jti": "token-unique-id"
   }
   ```

3. **Token Validation Strategy:**
   - Services validate JWT signature locally (no auth service call needed)
   - Services maintain in-memory revocation cache (refreshed from Kafka)
   - Check token expiration and revocation status
   - Fast path: signature + expiry check only
   - Revocation check: lookup in local cache

4. **Token Revocation Flow:**
   ```
   Auth Service:
   1. User requests token revocation
   2. Add token JTI to revocation table
   3. Publish TokenRevoked event to Kafka topic

   Other Services:
   1. Consume TokenRevoked events
   2. Update local revocation cache (in-memory set/bloom filter)
   3. Reject requests using revoked tokens
   4. Periodically sync revocation list from auth service (backup)
   ```

5. **Servant Integration:**
   ```haskell
   -- Declarative authorization
   type AccountAPI =
     -- Customer endpoint (owner-only access)
     "accounts" :> Capture "userId" UserId
                :> RequireAuth '["read:accounts:own"]
                :> RequireOwnership UserId
                :> Get '[JSON] Account

     -- Admin endpoint (all accounts)
     :<|> "accounts" :> RequireAuth '["admin"]
                     :> Get '[JSON] [Account]

     -- Service-to-service endpoint
     :<|> "internal" :> "accounts" :> RequireServiceAuth
                                   :> Get '[JSON] [Account]

   -- Helper types
   data TokenType = CustomerToken | AdminToken | ServiceToken
     deriving (Show, Eq)

   data AuthContext = AuthContext
     { authSubject :: Text        -- user-123, admin-456, service:account-service
     , authTokenType :: TokenType
     , authScopes :: [Scope]
     , authEmail :: Maybe Text    -- Nothing for service tokens
     , authServiceName :: Maybe Text  -- Just "account-service" for service tokens
     }

   -- Middleware extracts JWT and validates
   requireAuth :: [Scope] -> Handler AuthContext
   requireOwnership :: UserId -> AuthContext -> Handler ()
   requireAnyScope :: [Scope] -> AuthContext -> Handler ()
   requireServiceAuth :: Handler AuthContext  -- Service tokens only
   requireCustomerToken :: Handler AuthContext  -- Customer tokens only
   requireAdminToken :: Handler AuthContext     -- Admin tokens only
   ```

6. **Revocation Cache Implementation:**
   ```haskell
   -- In-memory cache with Kafka sync
   data RevocationCache = RevocationCache
     { revokedTokens :: TVar (Set TokenId)
     , lastSync :: TVar UTCTime
     }

   -- Kafka consumer updates cache
   handleTokenRevoked :: TokenRevokedEvent -> RIO env ()
   handleTokenRevoked event = do
     cache <- view revocationCacheL
     atomically $ modifyTVar (revokedTokens cache)
                    (Set.insert (tokenId event))

   -- Periodic full sync as backup
   syncRevocationList :: RIO env ()
   syncRevocationList = do
     tokens <- callAuthService "/revoked-tokens"
     cache <- view revocationCacheL
     atomically $ writeTVar (revokedTokens cache) (Set.fromList tokens)
   ```

**Challenges to consider:**
- Revocation propagation delay (eventual consistency)
  - Solution: Short token expiry (15 min) + refresh tokens
- Revocation cache memory usage
  - Solution: Bloom filters or TTL-based cleanup
- Clock skew between services (exp validation)
  - Solution: Allow small time window (±5 minutes)
- Key rotation for JWT signing
  - Solution: JWKS endpoint with key IDs in token header
- Offline validation vs revocation checking
  - Trade-off: Security vs performance

**Libraries to consider:**
- `jose` - JWT encoding/decoding (Haskell)
- `servant-auth` - Servant integration for JWT auth
- `wai-middleware-auth` - WAI-level auth middleware
- Redis or in-memory cache for revocation list

**Scope Examples:**

*Customer Scopes:*
- `read:accounts:own` - Read own account data
- `write:accounts:own` - Update own account
- `read:loans:own` - Read own loans only
- `read:transactions:own` - Read own transactions

*Admin Scopes:*
- `admin` - Full system access
- `read:*` - Read all resources
- `write:*` - Write all resources
- `read:accounts:all` - Read all accounts
- `write:accounts:all` - Modify all accounts
- `support:impersonate` - Impersonate users for support

*Service Scopes:*
- `service:read:users` - Service can read user data
- `service:write:notifications` - Service can send notifications
- `service:read:accounts` - Service can read account data
- `service:write:audit` - Service can write audit logs

**Token Lifecycle:**

*Customer/Admin Tokens:*
```
1. Login → Issue access token (15 min) + refresh token (7 days)
2. API requests → Validate access token (local + revocation check)
3. Access token expires → Use refresh token to get new access token
4. Logout → Revoke both tokens → Kafka event → All services update cache
5. Admin revokes user → Revoke all user's tokens → Kafka broadcast
```

*Service Tokens:*
```
1. Service startup → Request service token from auth service (using client credentials)
2. Token cached for duration (24h expiry)
3. Service-to-service calls → Include service token in Authorization header
4. Token expires → Auto-refresh using client credentials
5. Service shutdown/rotation → Revoke token → Kafka broadcast
6. Key compromise → Revoke all service tokens → Force re-authentication
```

**Benefits:**
- No centralized auth bottleneck (local JWT validation)
- Fast revocation propagation via Kafka
- Fine-grained authorization with scopes
- Owner-based access control
- Declarative endpoint security in Servant
- Audit trail of all auth events

**Implementation Steps:**
1. Create auth-service with user/scope management
2. Implement JWT signing and validation library wrapper
3. Add token type discrimination (customer/admin/service)
4. Add revocation cache to haskell-service-lib
5. Create Kafka topic for token revocation events
6. Implement Servant auth middleware with scope checking
7. Add owner verification helpers
8. Implement service-to-service authentication (client credentials flow)
9. Add service token auto-refresh mechanism
10. Create test utilities for authenticated requests (all token types)

**Service-to-Service Authentication Pattern:**
```haskell
-- In service startup
data AppEnv = AppEnv
  { ...
  , serviceToken :: TVar (Maybe ServiceToken)
  , serviceCredentials :: ServiceCredentials  -- From env vars
  }

-- Auto-refresh service token
refreshServiceToken :: RIO env ()
refreshServiceToken = do
  creds <- view (to serviceCredentials)
  newToken <- callAuthService "/oauth/token" $ ClientCredentials creds
  tokenVar <- view (to serviceToken)
  atomically $ writeTVar tokenVar (Just newToken)

-- HTTP client wrapper that adds service token
callOtherService :: Text -> Value -> RIO env Response
callOtherService url body = do
  token <- readTVarIO =<< view (to serviceToken)
  let headers = [("Authorization", "Bearer " <> encodeUtf8 (tokenValue token))]
  httpPost url headers body

-- Periodic refresh (run in background)
serviceTokenRefreshLoop :: RIO env ()
serviceTokenRefreshLoop = forever $ do
  threadDelay (23 * 60 * 60 * 1000000)  -- 23 hours
  refreshServiceToken
```


## Contract Testing Pipeline

Implement contract testing between services for HTTP APIs and Kafka messages.

**Goals:**
- Catch breaking changes between producer and consumer
- Generate test data from type definitions
- Validate JSON schema compatibility
- Run in CI pipeline before deployment
- Support both HTTP contracts and Kafka message contracts

**Architecture:**

1. **Contract Definition:**
   - Producer publishes contract (JSON schemas + examples)
   - Consumers declare what they expect
   - Test validates producer output matches consumer expectations

2. **HTTP Contract Testing:**
   ```haskell
   -- Producer side (account-service)
   -- Automatically generate examples from Servant API types
   generateHttpContracts :: Proxy AccountAPI -> [HttpContract]
   generateHttpContracts _ =
     [ HttpContract
         { contractEndpoint = "POST /accounts"
         , contractRequestExample = exampleCreateAccountRequest
         , contractResponseExample = exampleAccount
         , contractSchema = deriveSchema (Proxy @Account)
         }
     ]

   -- Save to file: contracts/account-service-http.json

   -- Consumer side (notification-service)
   testHttpContracts :: Spec
   testHttpContracts = do
     it "can decode account-service responses" $ do
       contracts <- loadContracts "account-service-http.json"
       forM_ contracts $ \contract -> do
         let decoded = decode @Account (contractResponseExample contract)
         decoded `shouldSatisfy` isJust
   ```

3. **Kafka Message Contract Testing:**
   ```haskell
   -- Producer side (account-service)
   -- Define message contracts
   kafkaContracts :: [KafkaContract]
   kafkaContracts =
     [ KafkaContract
         { contractTopic = "account-created"
         , contractMessageExample = exampleAccountCreatedEvent
         , contractSchema = deriveSchema (Proxy @AccountCreatedEvent)
         , contractProducer = "account-service"
         , contractVersion = "1.0"
         }
     ]

   -- Generate examples using QuickCheck/Hedgehog
   exampleAccountCreatedEvent :: Value
   exampleAccountCreatedEvent = toJSON $ AccountCreatedEvent
     { eventAccountId = 123
     , eventAccountName = "Test User"
     , eventAccountEmail = "test@example.com"
     }

   -- Save to: contracts/account-service-kafka.json

   -- Consumer side (notification-service)
   testKafkaContracts :: Spec
   testKafkaContracts = do
     it "can decode account-created events" $ do
       contracts <- loadKafkaContracts "account-service"
       let accountCreatedContract = find (\c -> contractTopic c == "account-created") contracts
       case accountCreatedContract of
         Just contract -> do
           let decoded = decode @AccountCreatedEvent (contractMessageExample contract)
           decoded `shouldSatisfy` isJust
         Nothing -> expectationFailure "Contract not found"
   ```

4. **Contract Registry:**
   - Central repository for all contracts (Git repo or artifact storage)
   - Versioned contracts (semantic versioning)
   - Producer publishes contracts on each release
   - Consumers download contracts during build/test

5. **CI Pipeline Integration:**
   ```bash
   # In producer CI
   1. Run tests
   2. Generate contracts from API types
   3. Publish contracts to registry
   4. Tag with version

   # In consumer CI
   1. Download contracts from registry
   2. Run contract tests
   3. Fail build if contracts don't match
   ```

**Implementation approach:**

1. **Add contract generation:**
   ```haskell
   -- packages/haskell-service-lib/src/Service/Contracts.hs
   module Service.Contracts where

   data HttpContract = HttpContract
     { contractEndpoint :: Text
     , contractMethod :: Text
     , contractRequestSchema :: Value
     , contractRequestExample :: Value
     , contractResponseSchema :: Value
     , contractResponseExample :: Value
     , contractProducer :: Text
     , contractVersion :: Text
     }

   data KafkaContract = KafkaContract
     { contractTopic :: Text
     , contractMessageSchema :: Value
     , contractMessageExample :: Value
     , contractProducer :: Text
     , contractVersion :: Text
     }

   -- Generate schema from type using aeson-schemas or similar
   deriveSchema :: forall a. (ToJSON a, Generic a) => Proxy a -> Value

   -- Generate example using QuickCheck Arbitrary
   generateExample :: forall a. (ToJSON a, Arbitrary a) => IO Value
   ```

2. **Add contract test utilities:**
   ```haskell
   -- Test that producer can encode and consumer can decode
   testContract :: forall producer consumer. (ToJSON producer, FromJSON consumer)
                => producer -> IO (Maybe consumer)
   testContract producerValue = do
     let encoded = encode producerValue
     return $ decode encoded

   -- Load contracts from JSON files
   loadHttpContracts :: FilePath -> IO [HttpContract]
   loadKafkaContracts :: Text -> IO [KafkaContract]  -- By service name
   ```

3. **CI script:**
   ```bash
   #!/bin/bash
   # scripts/publish-contracts.sh

   SERVICE_NAME=$1
   VERSION=$2

   # Generate contracts
   stack exec ${SERVICE_NAME}-generate-contracts

   # Publish to registry (S3, Git, Artifactory, etc.)
   aws s3 cp contracts/${SERVICE_NAME}-http.json \
     s3://contracts-registry/${SERVICE_NAME}/${VERSION}/http.json

   aws s3 cp contracts/${SERVICE_NAME}-kafka.json \
     s3://contracts-registry/${SERVICE_NAME}/${VERSION}/kafka.json
   ```

**Benefits:**
- Catch breaking changes before production
- Living documentation of APIs
- Confidence in refactoring
- No need for end-to-end tests for basic compatibility
- Faster feedback than integration tests

**Challenges:**
- Maintaining contracts as code evolves
- Versioning strategy (breaking vs non-breaking changes)
- Generating realistic test data
- Handling backward compatibility

**Example workflow:**
```
1. Developer changes AccountCreatedEvent in account-service
2. CI generates new contract with example JSON
3. CI publishes contract to registry
4. Notification-service CI downloads latest contracts
5. Contract tests fail because NotificationService expects old format
6. Developer updates NotificationService to handle new format
7. Both services deploy with compatible contracts
```

## Observability with Prometheus Metrics

Implement comprehensive metrics collection for HTTP endpoints, Kafka consumers, and database operations.

**Goals:**
- Track request latency, throughput, and error rates
- Monitor Kafka consumer lag and processing time
- Database connection pool metrics
- Custom business metrics
- Prometheus endpoint for scraping
- Grafana dashboard templates

**Architecture:**

1. **Metrics to Collect:**

   **HTTP Metrics:**
   - Request count by endpoint, method, status code
   - Request duration histogram
   - Request size histogram
   - Response size histogram
   - Active requests gauge
   - Rate of 4xx/5xx errors

   **Kafka Consumer Metrics:**
   - Messages consumed per topic
   - Message processing duration
   - Consumer lag per topic/partition
   - DLQ messages produced
   - Kafka consumer errors

   **Database Metrics:**
   - Query duration histogram
   - Connection pool size (active/idle/max)
   - Query errors by type
   - Transaction duration
   - Deadlock count

   **Business Metrics:**
   - Accounts created (counter)
   - Active users (gauge)
   - Feature usage counters
   - Custom domain events

2. **Implementation with prometheus-client:**
   ```haskell
   -- packages/haskell-service-lib/src/Service/Metrics.hs
   module Service.Metrics where

   import qualified Prometheus as P

   data Metrics = Metrics
     { -- HTTP metrics
       httpRequestsTotal :: P.Vector P.Label3 P.Counter
       -- Labels: method, endpoint, status
     , httpRequestDuration :: P.Vector P.Label2 P.Histogram
       -- Labels: method, endpoint
     , httpActiveRequests :: P.Gauge

       -- Kafka metrics
     , kafkaMessagesConsumed :: P.Vector P.Label1 P.Counter
       -- Labels: topic
     , kafkaMessageDuration :: P.Vector P.Label1 P.Histogram
       -- Labels: topic
     , kafkaConsumerLag :: P.Vector P.Label2 P.Gauge
       -- Labels: topic, partition
     , kafkaDLQMessages :: P.Vector P.Label2 P.Counter
       -- Labels: topic, error_type

       -- Database metrics
     , dbQueryDuration :: P.Vector P.Label1 P.Histogram
       -- Labels: operation (select, insert, update, delete)
     , dbConnectionsActive :: P.Gauge
     , dbConnectionsIdle :: P.Gauge
     , dbQueryErrors :: P.Vector P.Label1 P.Counter
       -- Labels: error_type
     }

   initMetrics :: IO Metrics
   initMetrics = do
     httpRequestsTotal <- P.register $ P.vector ("method", "endpoint", "status") $
       P.counter (P.Info "http_requests_total" "Total HTTP requests")

     httpRequestDuration <- P.register $ P.vector ("method", "endpoint") $
       P.histogram (P.Info "http_request_duration_seconds" "HTTP request duration")
         P.defaultBuckets

     httpActiveRequests <- P.register $
       P.gauge (P.Info "http_active_requests" "Currently active HTTP requests")

     kafkaMessagesConsumed <- P.register $ P.vector "topic" $
       P.counter (P.Info "kafka_messages_consumed_total" "Total Kafka messages consumed")

     kafkaMessageDuration <- P.register $ P.vector "topic" $
       P.histogram (P.Info "kafka_message_duration_seconds" "Kafka message processing duration")
         P.defaultBuckets

     kafkaConsumerLag <- P.register $ P.vector ("topic", "partition") $
       P.gauge (P.Info "kafka_consumer_lag" "Kafka consumer lag")

     kafkaDLQMessages <- P.register $ P.vector ("topic", "error_type") $
       P.counter (P.Info "kafka_dlq_messages_total" "Messages sent to DLQ")

     dbQueryDuration <- P.register $ P.vector "operation" $
       P.histogram (P.Info "db_query_duration_seconds" "Database query duration")
         P.defaultBuckets

     dbConnectionsActive <- P.register $
       P.gauge (P.Info "db_connections_active" "Active database connections")

     dbConnectionsIdle <- P.register $
       P.gauge (P.Info "db_connections_idle" "Idle database connections")

     dbQueryErrors <- P.register $ P.vector "error_type" $
       P.counter (P.Info "db_query_errors_total" "Database query errors")

     return Metrics {..}

   class HasMetrics env where
     metricsL :: Lens' env Metrics
   ```

3. **HTTP Middleware for Metrics:**
   ```haskell
   -- Automatic instrumentation of all HTTP endpoints
   metricsMiddleware :: Metrics -> Middleware
   metricsMiddleware metrics app req respond = do
     let method = decodeUtf8 $ requestMethod req
         path = decodeUtf8 $ rawPathInfo req

     -- Increment active requests
     P.incGauge (httpActiveRequests metrics)

     -- Time the request
     start <- getCurrentTime
     app req $ \response -> do
       end <- getCurrentTime
       let duration = realToFrac $ diffUTCTime end start
           status = statusCode $ responseStatus response

       -- Decrement active requests
       P.decGauge (httpActiveRequests metrics)

       -- Record metrics
       P.withLabel (httpRequestsTotal metrics) (method, path, tshow status) P.incCounter
       P.withLabel (httpRequestDuration metrics) (method, path) (`P.observe` duration)

       respond response
   ```

4. **Kafka Consumer Metrics:**
   ```haskell
   -- Wrap message handler with metrics
   instrumentKafkaHandler ::
     (HasMetrics env) =>
     TopicName ->
     (Value -> RIO env ()) ->
     (Value -> RIO env ())
   instrumentKafkaHandler topic handler = \value -> do
     metrics <- view (to metricsL)
     start <- liftIO getCurrentTime

     -- Increment messages consumed
     liftIO $ P.withLabel (kafkaMessagesConsumed metrics) (topicName topic) P.incCounter

     -- Run handler
     result <- tryAny (handler value)

     end <- liftIO getCurrentTime
     let duration = realToFrac $ diffUTCTime end start

     -- Record duration
     liftIO $ P.withLabel (kafkaMessageDuration metrics) (topicName topic)
       (`P.observe` duration)

     case result of
       Left err -> do
         -- If sent to DLQ, record it
         liftIO $ P.withLabel (kafkaDLQMessages metrics) (topicName topic, "handler_error")
           P.incCounter
         throwIO err
       Right _ -> return ()

   -- Update consumer lag periodically
   updateConsumerLag :: (HasMetrics env) => RIO env ()
   updateConsumerLag = forever $ do
     metrics <- view (to metricsL)
     -- Query Kafka for consumer lag
     lag <- getConsumerLag  -- Implementation using Kafka admin API
     forM_ lag $ \(topic, partition, lagAmount) ->
       liftIO $ P.withLabel (kafkaConsumerLag metrics) (topic, tshow partition)
         (`P.setGauge` fromIntegral lagAmount)
     threadDelay (30 * 1000000)  -- Update every 30s
   ```

5. **Database Metrics:**
   ```haskell
   -- Wrap database operations with metrics
   runDBWithMetrics ::
     (HasMetrics env, HasDB env, MonadUnliftIO m, MonadReader env m) =>
     SqlPersistT m a ->
     m a
   runDBWithMetrics action = do
     metrics <- view metricsL
     pool <- view dbL

     -- Update connection pool metrics
     liftIO $ do
       let (inUse, available, maxConn) = poolStats pool
       P.setGauge (dbConnectionsActive metrics) (fromIntegral inUse)
       P.setGauge (dbConnectionsIdle metrics) (fromIntegral available)

     -- Time the query
     start <- liftIO getCurrentTime
     result <- tryAny $ runSqlPool action pool
     end <- liftIO getCurrentTime

     let duration = realToFrac $ diffUTCTime end start
         operation = detectOperation action  -- Detect SELECT/INSERT/UPDATE/DELETE

     liftIO $ P.withLabel (dbQueryDuration metrics) operation (`P.observe` duration)

     case result of
       Left err -> do
         liftIO $ P.withLabel (dbQueryErrors metrics) (classifyError err) P.incCounter
         throwIO err
       Right val -> return val
   ```

6. **Prometheus Endpoint:**
   ```haskell
   -- Add to Servant API
   type MetricsAPI = "metrics" :> Get '[PlainText] Text

   metricsHandler :: Handler Text
   metricsHandler = liftIO $ do
     metrics <- P.exportMetricsAsText
     return $ decodeUtf8 metrics

   -- Complete API with metrics
   type API = MetricsAPI :<|> ...rest of API...
   ```

7. **Custom Business Metrics:**
   ```haskell
   -- Example: Track accounts created
   recordAccountCreated :: (HasMetrics env) => RIO env ()
   recordAccountCreated = do
     metrics <- view metricsL
     liftIO $ P.incCounter (accountsCreated metrics)

   -- Example: Track active users (from cache/DB)
   updateActiveUsers :: (HasMetrics env) => Int -> RIO env ()
   updateActiveUsers count = do
     metrics <- view metricsL
     liftIO $ P.setGauge (activeUsersGauge metrics) (fromIntegral count)
   ```

8. **Grafana Dashboard (JSON template):**
   ```json
   {
     "dashboard": {
       "title": "Service Overview",
       "panels": [
         {
           "title": "Request Rate",
           "targets": [
             {
               "expr": "rate(http_requests_total[5m])"
             }
           ]
         },
         {
           "title": "Request Duration (p95)",
           "targets": [
             {
               "expr": "histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))"
             }
           ]
         },
         {
           "title": "Error Rate",
           "targets": [
             {
               "expr": "rate(http_requests_total{status=~\"5..\"}[5m])"
             }
           ]
         },
         {
           "title": "Kafka Consumer Lag",
           "targets": [
             {
               "expr": "kafka_consumer_lag"
             }
           ]
         },
         {
           "title": "Database Query Duration (p95)",
           "targets": [
             {
               "expr": "histogram_quantile(0.95, rate(db_query_duration_seconds_bucket[5m]))"
             }
           ]
         },
         {
           "title": "DLQ Messages",
           "targets": [
             {
               "expr": "rate(kafka_dlq_messages_total[5m])"
             }
           ]
         }
       ]
     }
   }
   ```

9. **Prometheus Configuration:**
   ```yaml
   # prometheus.yml
   scrape_configs:
     - job_name: 'account-service'
       static_configs:
         - targets: ['account-service:8080']
       metrics_path: '/metrics'
       scrape_interval: 15s

     - job_name: 'notification-service'
       static_configs:
         - targets: ['notification-service:8080']
       metrics_path: '/metrics'
       scrape_interval: 15s
   ```

10. **Alert Rules:**
    ```yaml
    # alerts.yml
    groups:
      - name: service_alerts
        rules:
          - alert: HighErrorRate
            expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "High error rate detected"

          - alert: HighKafkaLag
            expr: kafka_consumer_lag > 1000
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Kafka consumer lag is high"

          - alert: SlowDatabaseQueries
            expr: histogram_quantile(0.95, rate(db_query_duration_seconds_bucket[5m])) > 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Database queries are slow"

          - alert: DLQGrowth
            expr: rate(kafka_dlq_messages_total[5m]) > 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "DLQ is growing rapidly"
    ```

**Dependencies:**
```yaml
# package.yaml
dependencies:
  - prometheus-client
  - prometheus-metrics-ghc  # For GHC runtime metrics
  - wai-middleware-prometheus
```

**Benefits:**
- Real-time visibility into system health
- Historical trends analysis
- Proactive alerting on issues
- Performance optimization insights
- Capacity planning data
- SLA monitoring
- Debugging production issues

**Implementation Steps:**
1. Add prometheus-client to dependencies
2. Create Service.Metrics module with metric definitions
3. Add metrics middleware to HTTP server
4. Instrument Kafka consumer with metrics
5. Wrap database operations with timing
6. Add /metrics endpoint to API
7. Deploy Prometheus server
8. Create Grafana dashboards
9. Configure alert rules

## Local Development Automation

Automate starting all services with proper environment configuration.

**Goals:**
- Single command to start all services
- Automatic environment variable management per service
- Service dependency ordering (start Kafka/DB first)
- Hot reload during development
- Easy cleanup and restart
- Service health checks

**Implementation Options:**

### **Option 1: Make/Task Commands (Simplest)**

```makefile
# Makefile at repo root
.PHONY: start stop restart logs clean dev

# Start all infrastructure
infra-start:
	@echo "Starting Kafka..."
	podman start kafka-container || podman run -d --name kafka-container \
		-p 9092:9092 apache/kafka:latest
	@echo "Waiting for Kafka to be ready..."
	@sleep 5
	@echo "Infrastructure ready!"

# Start account service
account-service:
	@echo "Starting account-service..."
	cd services/account-service && \
	export PORT=8080 && \
	export DB_TYPE=sqlite && \
	export DB_CONNECTION_STRING=":memory:" && \
	export KAFKA_BROKER=localhost:9092 && \
	export KAFKA_GROUP_ID=account-service-dev && \
	stack run

# Start all services in parallel
dev: infra-start
	@echo "Starting all services..."
	@make -j3 account-service auth-service notification-service

# Stop everything
stop:
	@echo "Stopping services..."
	@pkill -f "stack exec" || true
	@podman stop kafka-container || true

# View logs
logs:
	tail -f /tmp/*.log

# Clean and restart
restart: stop clean dev

clean:
	rm -f /tmp/*.log
	rm -f services/*/database.db
```

**Usage:**
```bash
make dev           # Start everything
make stop          # Stop everything
make restart       # Clean restart
make logs          # View logs
```

### **Option 2: direnv + .envrc (Per-Service Auto-loading)**

```bash
# Install direnv
brew install direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc

# services/account-service/.envrc
export PORT=8080
export DB_TYPE=sqlite
export DB_CONNECTION_STRING=":memory:"
export KAFKA_BROKER=localhost:9092
export KAFKA_GROUP_ID=account-service-dev
export KAFKA_DEAD_LETTER_TOPIC=DEADLETTER
export KAFKA_MAX_RETRIES=3

# Auto-loads when you cd into directory!
direnv allow

# services/auth-service/.envrc
export PORT=8081
export DB_TYPE=sqlite
export DB_CONNECTION_STRING="auth.db"
export KAFKA_BROKER=localhost:9092
export KAFKA_GROUP_ID=auth-service-dev

direnv allow
```

**Usage:**
```bash
cd services/account-service  # Env vars auto-loaded!
stack run                     # Uses correct env vars
```

### **Option 3: Process Manager (Overmind/Foreman)**

```bash
# Install overmind
brew install overmind

# Procfile at repo root
Procfile:
kafka: ./scripts/start-kafka.sh
postgres: ./scripts/start-postgres.sh
account-service: cd services/account-service && stack run
auth-service: cd services/auth-service && stack run
notification-service: cd services/notification-service && stack run

# .env at repo root (shared env vars)
KAFKA_BROKER=localhost:9092
DB_TYPE=sqlite

# services/account-service/.env (service-specific)
PORT=8080
SERVICE_NAME=account-service
KAFKA_GROUP_ID=account-service-dev
```

**Usage:**
```bash
overmind start              # Start everything
overmind connect kafka      # Attach to kafka logs
overmind restart account-service  # Restart single service
overmind kill               # Stop everything
```

### **Option 4: Custom Script (Most Flexible)**

```bash
#!/bin/bash
# scripts/dev.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEV]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cleanup function
cleanup() {
  log "Stopping services..."
  pkill -f "stack exec" || true
  podman stop kafka-container postgres-container 2>/dev/null || true
  exit 0
}

trap cleanup SIGINT SIGTERM

# Start infrastructure
start_infra() {
  log "Starting Kafka..."
  if ! podman ps | grep -q kafka-container; then
    podman start kafka-container 2>/dev/null || \
    podman run -d --name kafka-container -p 9092:9092 apache/kafka:latest
  fi

  log "Starting PostgreSQL..."
  if ! podman ps | grep -q postgres-container; then
    podman start postgres-container 2>/dev/null || \
    podman run -d --name postgres-container \
      -e POSTGRES_PASSWORD=dev \
      -p 5432:5432 postgres:15
  fi

  log "Waiting for services to be ready..."
  sleep 5
}

# Start a service with env vars
start_service() {
  local service_name=$1
  local port=$2

  log "Starting ${service_name} on port ${port}..."

  cd services/${service_name}

  # Service-specific env vars
  export PORT=${port}
  export SERVICE_NAME=${service_name}
  export KAFKA_BROKER=localhost:9092
  export KAFKA_GROUP_ID=${service_name}-dev
  export DB_TYPE=sqlite
  export DB_CONNECTION_STRING=":memory:"

  # Start in background, log to file
  stack run > /tmp/${service_name}.log 2>&1 &
  local pid=$!

  log "${service_name} started (PID: ${pid})"

  cd ../..
}

# Health check
health_check() {
  local service=$1
  local port=$2
  local max_attempts=30

  log "Checking ${service} health..."

  for i in $(seq 1 ${max_attempts}); do
    if curl -s http://localhost:${port}/status > /dev/null 2>&1; then
      log "${service} is healthy!"
      return 0
    fi
    sleep 1
  done

  error "${service} failed health check"
  return 1
}

# Main
main() {
  log "Starting development environment..."

  start_infra

  start_service "account-service" 8080
  start_service "auth-service" 8081
  start_service "notification-service" 8082

  sleep 5

  health_check "account-service" 8080
  health_check "auth-service" 8081
  health_check "notification-service" 8082

  log "All services running! Logs in /tmp/*.log"
  log "Press Ctrl+C to stop"

  # Keep script running
  wait
}

main
```

**Usage:**
```bash
chmod +x scripts/dev.sh
./scripts/dev.sh

# In another terminal
tail -f /tmp/account-service.log
curl http://localhost:8080/status
```

### **Option 5: Docker Compose (Alternative)**

```yaml
# docker-compose.yml
version: '3.8'

services:
  kafka:
    image: apache/kafka:latest
    ports:
      - "9092:9092"
    healthcheck:
      test: ["CMD", "kafka-topics.sh", "--list", "--bootstrap-server", "localhost:9092"]
      interval: 5s
      timeout: 10s
      retries: 5

  postgres:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: dev
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data

  account-service:
    build: ./services/account-service
    ports:
      - "8080:8080"
    environment:
      PORT: 8080
      DB_TYPE: postgres
      DB_CONNECTION_STRING: postgresql://postgres:dev@postgres:5432/services
      KAFKA_BROKER: kafka:9092
      KAFKA_GROUP_ID: account-service-dev
    depends_on:
      kafka:
        condition: service_healthy
      postgres:
        condition: service_started
    volumes:
      - ./services/account-service:/app  # Hot reload

volumes:
  postgres-data:
```

**Usage:**
```bash
docker-compose up          # Start all
docker-compose up -d       # Start in background
docker-compose logs -f     # Follow logs
docker-compose restart account-service  # Restart one service
docker-compose down        # Stop all
```

### **Recommended Approach: Combine Multiple**

```bash
# Use direnv for per-service env vars
# Use Makefile for common commands
# Use custom script for orchestration

# Makefile
include services/account-service/.env
export

dev:
	./scripts/dev.sh

test:
	cd services/account-service && stack test

build:
	stack build --fast

format:
	find . -name "*.hs" -exec ormolu --mode inplace {} \;
```

**Benefits:**
- No manual env var management
- One command to start everything
- Proper service ordering
- Easy to restart individual services
- Logs easily accessible
- Works with existing Stack setup

**Implementation Steps:**
1. Choose approach (recommend Makefile + direnv)
2. Create .envrc files for each service
3. Create Makefile with common commands
4. Create start-infra script for Kafka/DB
5. Add health check endpoints
6. Document in README

## Frontend Monorepo with Server-Side Rendering

Add React-based frontend with SSR deployed to AWS.

**Goals:**
- Server-side rendering for performance and SEO
- Shared components and utilities across apps
- Type-safe API client generation from Servant types
- Modern development experience
- Deploy to AWS (Lambda@Edge or ECS)
- CI/CD integration

**Framework Choice: Next.js**

**Why Next.js:**
- Built-in SSR and SSG (Static Site Generation)
- File-based routing
- API routes (can proxy to backend services)
- Excellent TypeScript support
- Image optimization
- Easy deployment to AWS (Amplify, Lambda, ECS)
- Large community and ecosystem

**Monorepo Structure:**

```
frontend/
├── package.json                    # Root workspace config
├── turbo.json                      # Turborepo config for caching
├── tsconfig.base.json             # Base TypeScript config
├── .eslintrc.js                   # Shared linting config
│
├── apps/
│   ├── web/                       # Main customer-facing app
│   │   ├── package.json
│   │   ├── next.config.js
│   │   ├── tsconfig.json
│   │   ├── src/
│   │   │   ├── app/              # Next.js 13+ app directory
│   │   │   │   ├── layout.tsx
│   │   │   │   ├── page.tsx
│   │   │   │   ├── accounts/
│   │   │   │   │   ├── page.tsx
│   │   │   │   │   └── [id]/page.tsx
│   │   │   │   └── api/          # API routes (proxies)
│   │   │   ├── components/
│   │   │   └── lib/
│   │   └── public/
│   │
│   ├── admin/                     # Admin dashboard
│   │   ├── package.json
│   │   ├── next.config.js
│   │   └── src/
│   │
│   └── dlq-ui/                    # DLQ management UI
│       ├── package.json
│       ├── next.config.js
│       └── src/
│
├── packages/
│   ├── ui/                        # Shared UI components
│   │   ├── package.json
│   │   ├── src/
│   │   │   ├── components/
│   │   │   │   ├── Button.tsx
│   │   │   │   ├── Input.tsx
│   │   │   │   └── Card.tsx
│   │   │   └── index.ts
│   │   └── tsconfig.json
│   │
│   ├── api-client/                # Generated API client
│   │   ├── package.json
│   │   ├── src/
│   │   │   ├── generated/        # Auto-generated from Servant
│   │   │   │   ├── account-service.ts
│   │   │   │   └── auth-service.ts
│   │   │   ├── client.ts         # HTTP client with auth
│   │   │   └── hooks.ts          # React Query hooks
│   │   └── codegen.config.ts
│   │
│   ├── utils/                     # Shared utilities
│   │   ├── package.json
│   │   └── src/
│   │       ├── format.ts
│   │       ├── validation.ts
│   │       └── constants.ts
│   │
│   └── tsconfig/                  # Shared TypeScript configs
│       ├── package.json
│       ├── base.json
│       ├── nextjs.json
│       └── react-library.json
│
└── scripts/
    ├── generate-api-client.sh    # Generate TypeScript from Servant
    └── deploy.sh
```

**Technology Stack:**

```json
{
  "dependencies": {
    "next": "^14.0.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "@tanstack/react-query": "^5.0.0",  // Data fetching
    "zod": "^3.22.0",                    // Runtime validation
    "zustand": "^4.4.0",                 // State management
    "tailwindcss": "^3.3.0",             // Styling
    "shadcn-ui": "latest"                // Component library
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "turbo": "^1.10.0",                  // Monorepo build system
    "@types/react": "^18.2.0",
    "eslint": "^8.0.0",
    "prettier": "^3.0.0"
  }
}
```

**API Client Generation:**

```typescript
// packages/api-client/src/generated/account-service.ts
// Auto-generated from Servant API types

export type Account = {
  id: number;
  name: string;
  email: string;
};

export type CreateAccountRequest = {
  name: string;
  email: string;
};

export class AccountServiceClient {
  constructor(private baseUrl: string, private token?: string) {}

  async getAccounts(): Promise<Account[]> {
    const response = await fetch(`${this.baseUrl}/accounts`, {
      headers: {
        'Authorization': `Bearer ${this.token}`,
        'Content-Type': 'application/json',
      },
    });
    return response.json();
  }

  async getAccount(id: number): Promise<Account> {
    const response = await fetch(`${this.baseUrl}/accounts/${id}`, {
      headers: { 'Authorization': `Bearer ${this.token}` },
    });
    return response.json();
  }

  async createAccount(req: CreateAccountRequest): Promise<Account> {
    const response = await fetch(`${this.baseUrl}/accounts`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${this.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(req),
    });
    return response.json();
  }
}

// React Query hooks
export function useAccounts() {
  return useQuery({
    queryKey: ['accounts'],
    queryFn: () => client.getAccounts(),
  });
}

export function useCreateAccount() {
  return useMutation({
    mutationFn: (data: CreateAccountRequest) => client.createAccount(data),
  });
}
```

**Example Next.js Page (SSR):**

```typescript
// apps/web/src/app/accounts/page.tsx
import { AccountList } from '@repo/ui/components/AccountList';
import { getAccounts } from '@repo/api-client';

export default async function AccountsPage() {
  // Server-side data fetching
  const accounts = await getAccounts();

  return (
    <div>
      <h1>Accounts</h1>
      <AccountList accounts={accounts} />
    </div>
  );
}

// Client-side interaction
'use client'
import { useCreateAccount } from '@repo/api-client';

export function CreateAccountForm() {
  const { mutate, isPending } = useCreateAccount();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    mutate({ name: 'John', email: 'john@example.com' });
  };

  return <form onSubmit={handleSubmit}>...</form>;
}
```

**Deployment Options:**

1. **AWS Amplify (Easiest):**
   - Fully managed Next.js hosting
   - Auto-deploy from Git
   - Built-in CDN
   - SSR and SSG support
   ```bash
   amplify init
   amplify add hosting
   amplify publish
   ```

2. **ECS with ALB (More control):**
   - Run Next.js as Docker container
   - Auto-scaling
   - Same infrastructure as backend
   ```dockerfile
   FROM node:18-alpine
   WORKDIR /app
   COPY package*.json ./
   RUN npm ci
   COPY . .
   RUN npm run build
   CMD ["npm", "start"]
   ```

3. **Lambda@Edge + CloudFront (Cost-effective):**
   - Serverless SSR
   - Global edge locations
   - Pay per request

**CI/CD:**

```yaml
# .github/workflows/frontend.yml
name: Frontend Deploy

on:
  push:
    branches: [main]
    paths: ['frontend/**']

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: 18

      - name: Install dependencies
        working-directory: ./frontend
        run: npm ci

      - name: Build
        working-directory: ./frontend
        run: npm run build

      - name: Deploy to AWS Amplify
        run: |
          npx amplify-cli publish --yes
```

**Benefits:**
- Fast initial page load (SSR)
- SEO-friendly
- Type-safe end-to-end (Haskell types → TypeScript types)
- Shared code across multiple frontend apps
- Modern development experience with hot reload
- Easy deployment to AWS

**Implementation Steps:**
1. Set up Next.js apps in frontend/ directory
2. Configure Turborepo for monorepo builds
3. Generate TypeScript types from Servant APIs
4. Create shared UI component library
5. Implement authentication flow
6. Deploy to AWS Amplify/ECS
7. Configure CDN and SSL

## Database Transaction Management

Implement automatic transaction boundaries for HTTP requests, Kafka messages, and tests.

**Goals:**
- Automatic transaction wrapping for HTTP handlers (commit on success, rollback on error)
- Automatic transaction wrapping for Kafka message handlers (commit on success, rollback on error)
- Test isolation using transactions (rollback after each test for clean state)
- Explicit transaction control when needed for complex workflows

**Implementation approach:**

1. **HTTP Request Transactions:**
   - Create middleware that wraps each request handler in a database transaction
   - Commit transaction on successful response (2xx/3xx status)
   - Rollback on handler exceptions or error responses (4xx/5xx)
   - Use Servant's custom monad or WAI middleware

2. **Kafka Message Transactions:**
   - Wrap message handlers in `runDBTransaction`
   - Commit transaction AND Kafka offset together (atomicity)
   - On rollback, don't commit Kafka offset (message will be reprocessed)
   - Consider idempotency for message handlers due to reprocessing

3. **Test Isolation:**
   - Wrap each test case in a transaction that always rolls back
   - Use `around` or `beforeAll` hooks to set up transaction context
   - Ensures tests don't affect each other's database state
   - Much faster than truncating tables between tests

**Persistent helpers to use:**
```haskell
runDBTransaction :: (MonadUnliftIO m, HasDB env, MonadReader env m)
                 => ReaderT SqlBackend m a -> m a
runDBTransaction action = do
  pool <- view dbL
  runSqlPool (runInTransaction action) pool

runInTransaction :: ReaderT SqlBackend m a -> ReaderT SqlBackend m a
runInTransaction = transactionSave -- or rawExecute "BEGIN" / "COMMIT"
```

**Challenges to consider:**
- Kafka offset commits must happen AFTER successful DB transaction commit
- Long-running transactions can cause lock contention
- Nested transaction handling (savepoints vs full transactions)
- Connection pool exhaustion with many concurrent transactions

**Example usage:**
```haskell
-- HTTP handler (automatic via middleware)
createAccountHandler req = do
  -- All DB operations in this handler are in one transaction
  accountId <- runDB $ insert account
  runDB $ insert auditLog
  -- Transaction commits on successful return

-- Kafka handler (explicit transaction)
accountCreatedHandler jsonValue = runDBTransaction $ do
  account <- parseAccountEvent jsonValue
  runDB $ insert notification
  runDB $ update accountStats
  -- Transaction commits, then Kafka offset commits

-- Test (automatic rollback)
it "creates account" $ runTestTransaction $ do
  accountId <- runDB $ insert testAccount
  account <- runDB $ get accountId
  -- Transaction rolls back after test
```

**Benefits:**
- Data consistency across operations
- Automatic error recovery via rollback
- Test isolation without manual cleanup
- Atomic Kafka message processing

## Automatic Entity Metadata

Add automatic tracking of metadata fields across all database entities:

**Metadata fields to track:**
- `createdAt` / `updatedAt` - Timestamps
- `createdByCid` / `updatedByCid` - Correlation IDs that triggered the action
- `createdByUserId` / `updatedByUserId` - User IDs (when available)

**Implementation approach:**
- Create `Models/Metadata.hs` with `HasMetadata` typeclass
- Add helper functions `withCreateMetadata` and `withUpdateMetadata` that automatically populate metadata from environment (correlation ID, timestamp, user context)
- Update all entity definitions to include metadata fields with `default=CURRENT_TIMESTAMP` for timestamps
- Implement typeclass instances for each entity to set metadata fields
- Update handlers to use metadata helpers instead of manually setting fields

**Benefits:**
- Automatic audit trail for all database operations
- Correlation ID tracking for debugging distributed operations
- User attribution without manual bookkeeping
- Consistent metadata across all tables

**Example usage:**
```haskell
createAccountHandler req = do
  let account = Account { accountName = ..., accountEmail = ... }
  accountWithMetadata <- withCreateMetadata userId account
  runDB $ insert accountWithMetadata
```
