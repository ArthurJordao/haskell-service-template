# Database Migrations

## Development

By default, migrations run automatically on app startup:

```bash
stack run
# Migrations run automatically (DB_AUTO_MIGRATE=true by default)
```

## Production

**IMPORTANT**: Disable auto-migrations in production to avoid race conditions with multiple instances.

### Option 1: Use the migration runner (Recommended)

```bash
# In your CI/CD pipeline, before deploying app instances:

# 1. Run migrations (single instance)
DB_AUTO_MIGRATE=false DB_PATH=/path/to/prod.db stack exec run-migrations

# 2. Deploy app instances with auto-migrate disabled
DB_AUTO_MIGRATE=false stack exec haskell-service-template-exe
```

### Option 2: Manual SQL migrations

If you want to review SQL before applying:

1. Generate migration SQL:
```bash
# Connect to an in-memory DB and export schema
stack ghci
> :l Models.Account
> import Database.Persist.Sqlite
> import Control.Monad.Logger
> runStderrLoggingT $ runSqlite ":memory:" $ printMigration migrateAll
```

2. Review and apply manually to production database

## Environment Variables

- `DB_PATH`: Database file path (default: `accounts.db`)
- `DB_POOL_SIZE`: Connection pool size (default: `10`)
- `DB_AUTO_MIGRATE`: Auto-run migrations on startup (default: `true`, set to `false` in production)

## Migration Safety

### How Persistent migrations work:

1. **Inspects current database** - Queries existing schema
2. **Compares with models** - Checks what should exist
3. **Generates diff** - Creates only necessary changes
4. **Applies changes** - Runs ALTER TABLE, CREATE TABLE, etc.

### Safe operations:
- ✅ Adding new tables
- ✅ Adding new columns (with defaults or nullable)
- ✅ Creating indexes

### Unsafe/Manual operations:
- ⚠️ Renaming columns (appears as DROP + ADD)
- ⚠️ Changing column types
- ⚠️ Dropping columns (data loss)
- ⚠️ Adding NOT NULL constraints to existing columns

For complex migrations, use raw SQL:

```haskell
runSqlPool (rawExecute "ALTER TABLE account ADD COLUMN age INTEGER DEFAULT 0" []) pool
```

## Multi-Instance Deployments

### The Problem
- Multiple app instances running `runMigration` simultaneously
- Race conditions on schema changes
- Lock contention during migrations

### Solutions

#### 1. Separate Migration Phase (Recommended)
```bash
# CI/CD Pipeline:
1. Build: stack build
2. Migrate: stack exec run-migrations  # Single instance
3. Deploy: Deploy N app instances with DB_AUTO_MIGRATE=false
```

#### 2. Database Locks (Postgres/MySQL)
Use advisory locks to ensure only one instance runs migrations:

```haskell
-- Acquire lock before migration
withResource pool $ \conn -> do
  rawExecute "SELECT pg_advisory_lock(123456)" []
  runMigration migrateAll
  rawExecute "SELECT pg_advisory_unlock(123456)" []
```

#### 3. External Migration Tool
- Use tools like `migrate`, `flyway`, or `liquibase`
- Store SQL files in version control
- Run migrations separately from app deployment

## Example Deployment

### Kubernetes
```yaml
# Job to run migrations before deployment
apiVersion: batch/v1
kind: Job
metadata:
  name: run-migrations
spec:
  template:
    spec:
      containers:
      - name: migrations
        image: your-app:latest
        command: ["stack", "exec", "run-migrations"]
        env:
        - name: DB_PATH
          value: "/data/prod.db"
        - name: DB_AUTO_MIGRATE
          value: "false"
      restartPolicy: OnFailure
---
# Then deploy app with auto-migrate disabled
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: app
        image: your-app:latest
        env:
        - name: DB_AUTO_MIGRATE
          value: "false"  # Important!
```

### Docker Compose
```yaml
version: '3'
services:
  migrate:
    image: your-app:latest
    command: stack exec run-migrations
    environment:
      - DB_PATH=/data/prod.db
      - DB_AUTO_MIGRATE=false
    volumes:
      - ./data:/data

  app:
    image: your-app:latest
    depends_on:
      migrate:
        condition: service_completed_successfully
    environment:
      - DB_AUTO_MIGRATE=false
    deploy:
      replicas: 3
```

## Troubleshooting

### "Table already exists" error
- Another instance created it first (race condition)
- Solution: Use `DB_AUTO_MIGRATE=false` and run migrations separately

### Migrations not applying
- Check `DB_AUTO_MIGRATE` is `true` (or run `run-migrations`)
- Verify database file permissions
- Check logs for migration SQL statements
