# Dead Letter Queue Service

Manages failed Kafka messages with storage, querying, and replay capabilities.

## How it works

1. Services that fail to process a Kafka message send it to the `DEADLETTER` topic
2. This service consumes from `DEADLETTER` and stores messages in the database
3. Operations team can inspect, replay, or discard messages via the REST API

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/status` | Health check |
| GET | `/dlq` | List messages (filters: `?status=`, `?topic=`, `?error_type=`) |
| GET | `/dlq/:id` | Get single message |
| POST | `/dlq/:id/replay` | Replay message to its original topic |
| POST | `/dlq/replay-batch` | Replay multiple messages (body: `[1, 2, 3]`) |
| POST | `/dlq/:id/discard` | Mark message as discarded |
| GET | `/dlq/stats` | Statistics breakdown |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `DB_TYPE` | `sqlite` | `sqlite` or `postgresql` |
| `DB_CONNECTION_STRING` | `:memory:` | Database connection string |
| `DB_AUTO_MIGRATE` | `false` | Run migrations on startup |
| `KAFKA_BROKER` | `localhost:9092` | Kafka broker address |
| `KAFKA_GROUP_ID` | `haskell-service-group` | Consumer group ID |
| `KAFKA_DEAD_LETTER_TOPIC` | `DEADLETTER` | Topic to consume from |

## Running

```bash
# Start Kafka
podman compose up -d

# Run the service
DB_TYPE=sqlite DB_CONNECTION_STRING=dlq.db DB_AUTO_MIGRATE=true stack run dead-letter-queue-exe

# Run migrations separately
DB_TYPE=sqlite DB_CONNECTION_STRING=dlq.db stack exec dead-letter-queue-migrations
```

## Tests

```bash
stack test dead-letter-queue
```
