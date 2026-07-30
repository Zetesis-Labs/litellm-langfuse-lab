#!/usr/bin/env bash
set -euo pipefail

# Crea los Secrets que necesitan los charts, con valores generados.
#   ./deploy/scripts/gen-secrets.sh [namespace]
# Requiere ANTHROPIC_API_KEY (y opcionalmente OPENAI_API_KEY) en el entorno.
# Idempotente: reaplica los mismos nombres de secret con valores nuevos.

NAMESPACE="${1:-${NAMESPACE:-llm-platform}}"

: "${ANTHROPIC_API_KEY:?exporta ANTHROPIC_API_KEY antes de ejecutar}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-$(openssl rand -hex 16)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 16)}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic langfuse-secrets \
  --from-literal=nextauth-secret="$(openssl rand -base64 32)" \
  --from-literal=salt="$(openssl rand -base64 32)" \
  --from-literal=encryption-key="$(openssl rand -hex 32)" \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=clickhouse-password="$CLICKHOUSE_PASSWORD" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic litellm-secrets \
  --from-literal=PROXY_MASTER_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic litellm-db \
  --from-literal=username=litellm \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secrets creados en el namespace $NAMESPACE."
echo "LITELLM_SALT_KEY cifra las credenciales guardadas en la base de datos:"
echo "si lo regeneras con datos ya escritos, dejan de poder descifrarse."
echo
echo "Master key del proxy:"
kubectl -n "$NAMESPACE" get secret litellm-secrets -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d
echo
