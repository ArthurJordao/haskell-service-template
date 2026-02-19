#!/usr/bin/env bash
# Usage: ./scripts/new-service.sh <service-name>
# Example: ./scripts/new-service.sh notification-service
set -euo pipefail

NAME="${1:?Usage: $0 <service-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/service.hsfiles"
SERVICES_DIR="$REPO_ROOT/services"
SERVICE_DIR="$SERVICES_DIR/$NAME"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found at $TEMPLATE" >&2
  exit 1
fi

if [[ -d "$SERVICE_DIR" ]]; then
  echo "ERROR: $SERVICE_DIR already exists" >&2
  exit 1
fi

echo "Creating service: $NAME"
# stack new fails at the resolver step (haskell-service-lib is a local package
# unknown to Stackage), but it still writes all source files before failing.
(cd "$SERVICES_DIR" && stack new "$NAME" "$TEMPLATE" --no-install-ghc 2>&1 || true)

if [[ ! -d "$SERVICE_DIR" ]]; then
  echo "ERROR: scaffold failed — $SERVICE_DIR was not created" >&2
  exit 1
fi

# stack new can't contain raw Mustache syntax (it treats {{}} as its own
# parameters), so we write the sample resource templates separately.
mkdir -p "$SERVICE_DIR/resources/templates"

cat > "$SERVICE_DIR/resources/templates/welcome_email.mustache" <<'MUSTACHE'
Subject: Welcome to our platform, {{name}}!

Dear {{name}},

Welcome! Your account has been created with the email address: {{email}}.

To get started, please visit: {{actionUrl}}

Best regards,
The Team
MUSTACHE

cat > "$SERVICE_DIR/resources/templates/password_reset.mustache" <<'MUSTACHE'
Subject: Password Reset Request

Dear {{name}},

We received a request to reset the password for your account ({{email}}).

Click the link below to reset your password (expires in {{expiryMinutes}} minutes):
{{resetUrl}}

If you did not request this, please ignore this email.

Best regards,
The Team
MUSTACHE

echo ""
echo "Service created at services/$NAME"
echo ""
echo "Next steps:"
echo "  1. Add to stack.yaml packages:"
echo "       - services/$NAME"
echo ""
echo "  2. Customise for your domain:"
echo "       src/Domain/Notifications.hs  — rename types / logic"
echo "       src/Ports/Consumer.hs        — update topic name"
echo "       src/Ports/Server.hs          — add HTTP routes if needed"
echo "       resources/templates/         — replace sample Mustache templates"
echo "       test/Spec.hs                 — update test fixtures"
echo ""
echo "  3. Build and test:"
echo "       stack build $NAME"
echo "       stack test $NAME"
