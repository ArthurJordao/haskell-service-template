# account-service

Account service for managing user accounts.

## Features

- HTTP API for account management
- Kafka integration for event streaming
- SQLite database with automatic migrations
- Correlation ID tracking across requests
- Structured logging with RIO

## Running

```bash
stack exec account-service-exe
```

## Configuration

Environment variables:
- `PORT` - HTTP server port (default: 8080)
- `ENVIRONMENT` - Environment name (default: development)
- `DB_PATH` - SQLite database path (default: accounts.db)
- `DB_POOL_SIZE` - Database connection pool size (default: 10)
- `DB_AUTO_MIGRATE` - Run migrations on startup (default: true)
- `KAFKA_BROKER` - Kafka broker address (default: localhost:9092)
- `KAFKA_GROUP_ID` - Kafka consumer group ID (default: haskell-service-group)

## Migrations

Run migrations manually:

```bash
stack exec account-service-migrations
```

## Testing

```bash
stack test account-service
```
