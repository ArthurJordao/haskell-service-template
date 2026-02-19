# notification-service

Generated from the monorepo service template.

## Quickstart

### 1. Add to the monorepo

```
# In stack.yaml, add under packages:
- services/notification-service
```

### 2. Customise the domain

- Rename `Domain/Notifications.hs` and its types to match your domain.
- Update the Kafka topic in `Ports/Consumer.hs`.
- Add HTTP routes to `Ports/Server.hs` as needed.

### 3. Build and run

```sh
stack build notification-service
stack run notification-service-exe
stack test notification-service
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP server port |
| `ENVIRONMENT` | `development` | Runtime environment |
| `KAFKA_BROKER` | `localhost:9092` | Kafka broker address |
| `KAFKA_GROUP_ID` | `notification-service` | Consumer group ID |
| `KAFKA_DEAD_LETTER_TOPIC` | `DEADLETTER` | DLQ topic name |
| `KAFKA_MAX_RETRIES` | `3` | Max retries before DLQ |
| `TEMPLATES_DIR` | `resources/templates` | Path to Mustache templates |

## Architecture

```
src/
  App.hs              RIO environment, instance declarations
  Lib.hs              Startup orchestration
  Settings.hs         Environment variable loading
  Domain/
    Notifications.hs  Business logic — rename to your domain
  Ports/
    Server.hs         Servant HTTP adapter (thin — delegates to Domain)
    Consumer.hs       Kafka consumer config + handlers
resources/
  templates/          Mustache email templates (.mustache)
```
