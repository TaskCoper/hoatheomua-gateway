#!/usr/bin/env bash
# Push values from .docker/.env up to GitHub as *environment* secrets,
# so deploy-application.yaml can read them via `secrets: inherit`.
#
# Usage:
#   ./.docker/sync-env-secrets.sh                 # dev + prod from .docker/.env
#   ENVIRONMENTS="dev" ./.docker/sync-env-secrets.sh
#   ENV_FILE=.docker/.env.prod ENVIRONMENTS="prod" ./.docker/sync-env-secrets.sh
set -euo pipefail

REPO="${REPO:-TaskCoper/hoatheomua-gateway}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"

# Keys present in .env that should NOT become secrets (computed in CI).
EXCLUDE='^(REGISTRY|TAG)='

[ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }

for ENV in $ENVIRONMENTS; do
  echo ">> Ensuring environment '$ENV' exists..."
  gh api -X PUT "repos/$REPO/environments/$ENV" --silent

  echo ">> Setting secrets for '$ENV' from $ENV_FILE ..."
  gh secret set \
    --repo "$REPO" \
    --env "$ENV" \
    --env-file <(grep -vE '^[[:space:]]*#' "$ENV_FILE" | grep '=' | grep -vE "$EXCLUDE")

  echo ">> Done '$ENV'."
done

echo "All set. Verify with: gh secret list --repo $REPO --env dev"
