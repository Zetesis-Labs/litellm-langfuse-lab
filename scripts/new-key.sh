#!/usr/bin/env bash
set -euo pipefail

# Crea una virtual key en LiteLLM con presupuesto, para atribuir gasto por consumidor.
#   ./scripts/new-key.sh <alias> [max_budget_usd] [budget_duration]

ALIAS="${1:?uso: new-key.sh <alias> [max_budget_usd] [budget_duration]}"
BUDGET="${2:-5}"
DURATION="${3:-30d}"

MASTER_KEY="${LITELLM_MASTER_KEY:-sk-lab-master-key}"
BASE_URL="${LITELLM_BASE_URL:-http://localhost:${LITELLM_PORT:-4000}}"

curl -sS -X POST "${BASE_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d @- <<EOF | python3 -m json.tool
{
  "key_alias": "${ALIAS}",
  "user_id": "${ALIAS}",
  "max_budget": ${BUDGET},
  "budget_duration": "${DURATION}",
  "metadata": {"spend_logs_metadata": {"consumer": "${ALIAS}"}}
}
EOF
