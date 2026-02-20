#!/usr/bin/env bash
set -euo pipefail

SERVICE="${1:-}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service-name>"
  echo "Available: account-service auth-service dead-letter-queue notification-service"
  exit 1
fi

SERVICE_DIR="services/$SERVICE"

if [ ! -d "$SERVICE_DIR" ]; then
  echo "Error: '$SERVICE_DIR' not found"
  exit 1
fi

# Capture repo root before cd so the log path is always absolute.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

if [ -f "$SERVICE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SERVICE_DIR/.env"; set +a
else
  echo "Warning: no .env found at $SERVICE_DIR/.env — run 'make setup' to create one"
fi

cd "$SERVICE_DIR"
# Tee stderr+stdout to a log file so Promtail can ship it to Loki while still
# printing to the terminal.
stack exec "$SERVICE-exe" 2>&1 | tee "$LOG_DIR/$SERVICE.log"
