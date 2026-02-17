# Observability with Metrics

The `haskell-service-lib` includes a modular metrics collection system for monitoring HTTP endpoints, Kafka consumers, and database operations.

## Architecture

The metrics system is organized into separate modules by concern:

- **`Service.Metrics.Core`** - Base metric types (Counter, Gauge, Histogram)
- **`Service.Metrics.Http`** - HTTP request metrics and middleware
- **`Service.Metrics.Kafka`** - Kafka consumer metrics and instrumentation
- **`Service.Metrics.Database`** - Database query metrics and instrumentation
- **`Service.Metrics.Optional`** - Optional type classes for automatic instrumentation
- **`Service.Metrics`** - Combined container that re-exports everything

### How Automatic Instrumentation Works

The library uses **optional type classes** with default no-op implementations:

```haskell
class OptionalKafkaMetrics env where
  recordKafkaMessageMetrics :: ...
  -- Default: does nothing

class OptionalDatabaseMetrics env where
  recordDatabaseQueryMetrics :: ...
  -- Default: does nothing
```

When you add metrics to your App:
1. Default instance provides no-op (service works without metrics)
2. When `HasKafkaMetrics` is present, an overlapping instance collects real metrics
3. No code changes needed in handlers!

This modular design allows you to:
- Use only the metrics modules you need
- Automatic instrumentation (no manual wrapping)
- Services work with or without metrics
- Easily extend with custom metrics
- Keep concerns separated and maintainable

## Features

- **Automatic Instrumentation**: Metrics are collected automatically when available (no manual wrapping!)
- **HTTP Metrics**: Request counts, duration histograms, active requests
- **Kafka Metrics**: Messages consumed, processing duration, DLQ messages
- **Database Metrics**: Query duration, connection pool stats, query errors
- **Prometheus-compatible**: Exports metrics in Prometheus text format
- **In-memory implementation**: No external dependencies required
- **Thread-safe**: Uses STM for concurrent access
- **Modular**: Import only what you need
- **Optional**: Services without metrics work fine (no-op defaults)

## Quick Start

### Option 1: Use All Metrics (Recommended)

```haskell
import Service.Metrics

data App = App
  { appLogFunc :: !LogFunc,
    appMetrics :: !Metrics,
    -- ... other fields
  }

instance HasMetrics App where
  metricsL = lens appMetrics (\x y -> x {appMetrics = y})

initializeApp :: IO App
initializeApp = do
  logFunc <- ...
  metrics <- initMetrics  -- Initialize all metrics
  return App { appMetrics = metrics, ... }
```

### Option 2: Use Individual Metric Modules

```haskell
import Service.Metrics.Http
import Service.Metrics.Kafka

data App = App
  { appLogFunc :: !LogFunc,
    appHttpMetrics :: !HttpMetrics,
    appKafkaMetrics :: !KafkaMetrics,
    -- ... other fields
  }

instance HasHttpMetrics App where
  httpMetricsL = lens appHttpMetrics (\x y -> x {appHttpMetrics = y})

instance HasKafkaMetrics App where
  kafkaMetricsL = lens appKafkaMetrics (\x y -> x {appKafkaMetrics = y})

initializeApp :: IO App
initializeApp = do
  logFunc <- ...
  httpMetrics <- initHttpMetrics
  kafkaMetrics <- initKafkaMetrics
  return App { appHttpMetrics = httpMetrics, appKafkaMetrics = kafkaMetrics, ... }
```

### 2. Add Metrics Middleware to HTTP Server

```haskell
import qualified Network.Wai as Wai
import Service.Metrics.Http (metricsMiddleware)

app :: App -> Application
app baseEnv = do
  -- If using combined Metrics
  let httpMetrics = metricsHttp (appMetrics baseEnv)
  httpMetricsVar <- newTVarIO httpMetrics

  -- OR if using HttpMetrics directly
  -- httpMetricsVar <- newTVarIO (appHttpMetrics baseEnv)

  let metricsMiddle = metricsMiddleware httpMetricsVar
  metricsMiddle $ \req -> do
    -- Your regular application handler
    serveWithContext api ...
```

### 3. Add /metrics Endpoint

```haskell
import Servant
import Service.Metrics (metricsHandler)

type API =
     "status" :> Get '[JSON] Text
  :<|> "metrics" :> Get '[PlainText] Text
  :<|> ... rest of your API ...

server :: (HasMetrics env) => Routes (AsServerT (RIO env))
server = Routes
  { status = statusHandler
  , metrics = metricsEndpointHandler
  , ...
  }

metricsEndpointHandler :: (HasMetrics env) => RIO env Text
metricsEndpointHandler = do
  metrics <- view metricsL
  liftIO $ metricsHandler metrics
```

### 4. Kafka Handlers (Automatic!)

Kafka handlers are automatically instrumented - no manual wrapping needed!

```haskell
import Service.Kafka (TopicHandler(..))

-- Just define your handler as normal
accountCreatedHandler :: (HasLogFunc env) => Value -> RIO env ()
accountCreatedHandler jsonValue = do
  account <- parseAccountEvent jsonValue
  logInfo $ "Processing account: " <> displayShow account
  -- Metrics are automatically collected!
```

If your environment has `HasKafkaMetrics`, metrics will be collected automatically.
If not, the handler still works but without metrics (no-op).

### 5. Database Operations (Automatic!)

Database operations are automatically instrumented when you use `runSqlPoolWithCid` - no manual wrapping needed!

```haskell
import Service.Database (runSqlPoolWithCid)

getAccountHandler :: (HasLogFunc env, HasDB env) => Int -> RIO env Account
getAccountHandler accountId = do
  pool <- view dbL
  maybeAccount <- runSqlPoolWithCid (get (toSqlKey accountId)) pool
  case maybeAccount of
    Just account -> return account
    Nothing -> throwM err404
  -- Metrics are automatically collected!
```

If your environment has `HasDatabaseMetrics`, metrics will be collected automatically.
If not, queries still work but without metrics (no-op).

## Metrics Collected

### HTTP Metrics

- `http_requests_total{method, endpoint, status}` - Counter of HTTP requests
- `http_request_duration_seconds{method, endpoint}` - Histogram of request durations
- `http_active_requests` - Gauge of currently active requests

### Kafka Metrics

- `kafka_messages_consumed_total{topic}` - Counter of messages consumed
- `kafka_message_duration_seconds{topic}` - Histogram of message processing time
- `kafka_dlq_messages_total{topic, error_type}` - Counter of messages sent to DLQ

### Database Metrics

- `db_query_duration_seconds{operation}` - Histogram of query durations
- `db_connections_active` - Gauge of active connections
- `db_connections_idle` - Gauge of idle connections
- `db_query_errors_total{error_type}` - Counter of query errors

## Example Prometheus Queries

### HTTP Request Rate
```promql
rate(http_requests_total[5m])
```

### 95th Percentile Request Duration
```promql
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### Error Rate
```promql
rate(http_requests_total{status=~"5.."}[5m])
```

### Kafka Consumer Lag (approximated from processing time)
```promql
kafka_message_duration_seconds
```

### Database Query Errors
```promql
rate(db_query_errors_total[5m])
```

## Prometheus Configuration

Add this to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'account-service'
    static_configs:
      - targets: ['account-service:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

## Grafana Dashboards

Create dashboards with panels for:

1. **Request Rate**: Track incoming requests per second
2. **Request Duration**: Monitor latency (p50, p95, p99)
3. **Error Rate**: Alert on 4xx/5xx errors
4. **Kafka Throughput**: Messages processed per second
5. **Database Performance**: Query duration and error rates

## Advanced Usage

### Custom Metrics

You can add custom business metrics by extending the `Metrics` data structure:

```haskell
data Metrics = Metrics
  { -- Standard metrics
    httpRequestsTotal :: ...,
    -- Custom metrics
    accountsCreated :: !(Map Text Counter),
    activeUsers :: !Gauge
  }
```

Then use the metric operations:

```haskell
recordAccountCreated :: (HasMetrics env) => RIO env ()
recordAccountCreated = do
  metrics <- view metricsL
  counter <- liftIO $ atomically $ do
    case Map.lookup "accounts" (accountsCreated metrics) of
      Just c -> return c
      Nothing -> unsafeIOToSTM newCounter
  liftIO $ incCounter counter
```

### Path Normalization

The middleware automatically normalizes paths to reduce cardinality:
- `/accounts/123` → `/accounts/:id`
- `/accounts/456` → `/accounts/:id`

This prevents metrics explosion when dealing with dynamic URL parameters.

## Architecture

The metrics system uses:
- **STM (Software Transactional Memory)** for thread-safe concurrent updates
- **In-memory storage** with no external dependencies
- **Lazy initialization** of metrics (created on first use)
- **Histogram buckets**: Default buckets at 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s

## Performance Considerations

- Metrics are collected in-memory with minimal overhead
- Uses STM for lock-free concurrent updates
- Path normalization reduces cardinality
- Histogram bucketing is efficient for percentile calculations

## Future Enhancements

- Add prometheus-client library support for official Prometheus integration
- Implement consumer lag tracking via Kafka admin API
- Add database connection pool monitoring
- Support for custom histogram buckets
- Metrics persistence across restarts

## Troubleshooting

### Metrics endpoint returns empty

Ensure you've initialized metrics and added the middleware:

```haskell
metrics <- initMetrics
metricsVar <- newTVarIO metrics
let app = metricsMiddleware metricsVar yourApp
```

### Metrics not updating

Check that:
1. The middleware is applied to all requests
2. Instrumentation wrappers are used for Kafka and DB operations
3. The `HasMetrics` instance is correctly implemented

### High memory usage

Metrics are stored in-memory. If you have high cardinality (many unique label combinations), consider:
1. Better path normalization
2. Limiting the number of unique error types
3. Aggregating metrics before export
