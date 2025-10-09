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
- `DB_TYPE` - Database type: `sqlite` or `postgresql` (default: sqlite)
- `DB_CONNECTION_STRING` - Database connection string:
  - SQLite: file path (default: `accounts.db`)
  - PostgreSQL: connection string (default: `host=localhost port=5432 user=postgres dbname=accounts password=postgres`)
- `DB_POOL_SIZE` - Database connection pool size (default: 10)
- `DB_AUTO_MIGRATE` - Run migrations on startup (default: true)
- `KAFKA_BROKER` - Kafka broker address (default: localhost:9092)
- `KAFKA_GROUP_ID` - Kafka consumer group ID (default: haskell-service-group)

### Database Examples

**SQLite (default):**
```bash
# Uses default file-based database
stack exec account-service-exe

# Or specify custom path
DB_CONNECTION_STRING=my-database.db stack exec account-service-exe
```

**PostgreSQL:**
```bash
DB_TYPE=postgresql \
DB_CONNECTION_STRING="host=localhost port=5432 user=myuser dbname=accounts password=mypass" \
stack exec account-service-exe
```

## Migrations

Run migrations manually:

```bash
stack exec account-service-migrations
```

## Testing

```bash
stack test account-service
```
