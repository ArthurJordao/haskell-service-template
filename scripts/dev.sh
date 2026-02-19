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

if [ -f "$SERVICE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SERVICE_DIR/.env"; set +a
else
  echo "Warning: no .env found at $SERVICE_DIR/.env — run 'make setup' to create one"
fi

cd "$SERVICE_DIR"
exec ghcid \
  --command="stack ghci ${SERVICE}:lib ${SERVICE}:exe:${SERVICE}-exe --ghci-options=-Wwarn" \
  --test=":main"
