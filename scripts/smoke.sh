#!/usr/bin/env bash
set -euo pipefail

# Comprueba el camino completo: FastAPI -> LiteLLM -> modelo -> coste -> Langfuse -> lectura del gasto.

API="http://localhost:${API_PORT:-8000}"
MODEL="${1:-mock}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
jshow() { python3 -m json.tool < "$1"; }

step "Salud del stack"
curl -sS "${API}/healthz" -o "${TMP}/health.json"
jshow "${TMP}/health.json"

step "Modelos publicados por el proxy"
curl -sS "${API}/models" -o "${TMP}/models.json"
jshow "${TMP}/models.json"

step "Consulta al modelo ${MODEL}"
CODE=$(curl -sS -X POST "${API}/ask" \
  -H 'Content-Type: application/json' \
  -o "${TMP}/ask.json" -w '%{http_code}' \
  -d "{\"prompt\":\"Responde solo: hola\",\"model\":\"${MODEL}\",\"session_id\":\"smoke\",\"user_id\":\"smoke-user\",\"tags\":[\"smoke\"]}")
jshow "${TMP}/ask.json"

if [ "${CODE}" != "200" ]; then
  printf '\n\033[31mLa llamada falló con HTTP %s.\033[0m\n' "${CODE}"
  printf 'Si el modelo no es "mock", revisa que la API key del proveedor esté en .env.\n'
  TRACE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["detail"]["trace_id"])' "${TMP}/ask.json" 2>/dev/null || true)
  [ -n "${TRACE}" ] && printf 'El fallo quedó trazado como ERROR en: %s/traces/%s\n' "${API}" "${TRACE}"
  exit 1
fi

TRACE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["trace_id"])' "${TMP}/ask.json")
COST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cost_usd"])' "${TMP}/ask.json")
URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["langfuse_trace_url"])' "${TMP}/ask.json")

step "Gasto registrado en Langfuse para esta traza"
for _ in $(seq 1 20); do
  curl -sS "${API}/traces/${TRACE}" -o "${TMP}/trace.json"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["ingested"] else 1)' "${TMP}/trace.json"; then
    break
  fi
  sleep 3
done
jshow "${TMP}/trace.json"

step "Gasto acumulado en LiteLLM (últimas llamadas)"
curl -sS "${API}/spend/summary" -o "${TMP}/spend.json"
python3 - "${TMP}/spend.json" <<'PY'
import json, sys

rows = json.load(open(sys.argv[1]))
rows = rows if isinstance(rows, list) else [rows]
total = sum(float(r.get("spend") or 0) for r in rows)
rows.sort(key=lambda r: r.get("startTime") or "", reverse=True)
for row in rows[:5]:
    print(f"  {row.get('startTime', '?')}  {row.get('model_group', '?'):<18} "
          f"{row.get('total_tokens', 0):>6} tok  {float(row.get('spend') or 0):.8f} USD")
print(f"\n  {len(rows)} llamadas registradas, gasto total {total:.8f} USD")
PY

printf '\n\033[1mCoste de esta llamada:\033[0m %s USD\n' "${COST}"
printf '\033[1mTraza en Langfuse:\033[0m %s\n' "${URL}"
