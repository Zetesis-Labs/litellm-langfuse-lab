#!/usr/bin/env bash
set -euo pipefail

# Crea el namespace y los cuatro Secrets que necesitan los charts.
#   ./deploy/scripts/gen-secrets.sh [namespace]
#
# Requiere ANTHROPIC_API_KEY en el entorno. Las contraseñas de los servicios
# gestionados (RDS, ElastiCache, ClickHouse) se pasan también por entorno: si no
# las das, se generan, y entonces tendrás que ponerlas tú en esos servicios.
#
# Idempotente: se puede reejecutar. Ojo, regenera los valores que no fijes.

NAMESPACE="${1:-${NAMESPACE:-llm-platform}}"

: "${ANTHROPIC_API_KEY:?exporta ANTHROPIC_API_KEY antes de ejecutar}"

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-$(openssl rand -hex 16)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 16)}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-pk-lf-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-sk-lf-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
LANGFUSE_USER_EMAIL="${LANGFUSE_USER_EMAIL:-admin@example.com}"
LANGFUSE_USER_PASSWORD="${LANGFUSE_USER_PASSWORD:-$(openssl rand -base64 18)}"
PROXY_MASTER_KEY="${PROXY_MASTER_KEY:-sk-$(openssl rand -hex 24)}"

apply() { kubectl -n "$NAMESPACE" create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Secretos de la aplicación Langfuse y de sus dependencias.
# NEXTAUTH_SECRET y SALT en base64; ENCRYPTION_KEY en hex de 64 caracteres.
apply langfuse-secrets \
  --from-literal=nextauth-secret="$(openssl rand -base64 32)" \
  --from-literal=salt="$(openssl rand -base64 32)" \
  --from-literal=encryption-key="$(openssl rand -hex 32)" \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=clickhouse-password="$CLICKHOUSE_PASSWORD" \
  --from-literal=redis-password="$REDIS_PASSWORD"

# Auto-provisioning: el chart no lo modela, entra entero por additionalEnvFrom.
apply langfuse-init \
  --from-literal=LANGFUSE_INIT_ORG_ID=platform \
  --from-literal=LANGFUSE_INIT_ORG_NAME=Platform \
  --from-literal=LANGFUSE_INIT_PROJECT_ID=prod \
  --from-literal=LANGFUSE_INIT_PROJECT_NAME="LLM Gateway" \
  --from-literal=LANGFUSE_INIT_PROJECT_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  --from-literal=LANGFUSE_INIT_PROJECT_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  --from-literal=LANGFUSE_INIT_USER_EMAIL="$LANGFUSE_USER_EMAIL" \
  --from-literal=LANGFUSE_INIT_USER_NAME="Platform Admin" \
  --from-literal=LANGFUSE_INIT_USER_PASSWORD="$LANGFUSE_USER_PASSWORD"

# LITELLM_SALT_KEY cifra las credenciales guardadas en la base de datos del proxy:
# si lo rotas con datos ya escritos, dejan de poder descifrarse.
apply litellm-secrets \
  --from-literal=PROXY_MASTER_KEY="$PROXY_MASTER_KEY" \
  --from-literal=LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-}"

apply litellm-db \
  --from-literal=username="${DB_USERNAME:-litellm}" \
  --from-literal=password="$POSTGRES_PASSWORD"

cat <<EOF

Secrets creados en el namespace $NAMESPACE.

Guarda esto (no vuelve a mostrarse):
  Master key del proxy    : $PROXY_MASTER_KEY
  Langfuse public key     : $LANGFUSE_PUBLIC_KEY
  Langfuse secret key     : $LANGFUSE_SECRET_KEY
  Usuario de Langfuse     : $LANGFUSE_USER_EMAIL / $LANGFUSE_USER_PASSWORD

La contraseña de Postgres ($POSTGRES_PASSWORD) tiene que coincidir con la del
usuario en RDS. Lo mismo con Redis y ClickHouse si tienen autenticación.
EOF
