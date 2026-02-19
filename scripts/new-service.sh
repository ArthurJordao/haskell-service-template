#!/usr/bin/env bash
# Usage: ./scripts/new-service.sh <service-name>
# Example: ./scripts/new-service.sh notification-service
set -euo pipefail

NAME="${1:?Usage: $0 <service-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/service.hsfiles"
SERVICES_DIR="$REPO_ROOT/services"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found at $TEMPLATE" >&2
  exit 1
fi

if [[ -d "$SERVICES_DIR/$NAME" ]]; then
  echo "ERROR: $SERVICES_DIR/$NAME already exists" >&2
  exit 1
fi

echo "Creating service: $NAME"
(cd "$SERVICES_DIR" && stack new "$NAME" "$TEMPLATE" --no-install-ghc)

echo ""
echo "Service created at services/$NAME"
echo ""
echo "Next steps:"
echo "  1. Add to stack.yaml packages:"
echo "       - services/$NAME"
echo ""
echo "  2. Rename the placeholder domain (Item → your entity):"
echo "       src/Models/Item.hs"
echo "       src/Domain/Items.hs"
echo "       src/Ports/Repository.hs"
echo "       src/Ports/Produce.hs"
echo "       src/Ports/Server.hs"
echo "       test/Spec.hs"
echo ""
echo "  3. Build and test:"
echo "       stack build $NAME"
echo "       stack test $NAME"
