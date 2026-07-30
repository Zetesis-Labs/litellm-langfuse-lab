#!/usr/bin/env bash
set -euo pipefail

# Imprime un bloque de secretos listo para pegar en .env.
# Langfuse exige base64 para NEXTAUTH_SECRET/SALT y hex de 64 caracteres para ENCRYPTION_KEY.

cat <<EOF
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)
LITELLM_SALT_KEY=sk-$(openssl rand -hex 24)
LANGFUSE_NEXTAUTH_SECRET=$(openssl rand -base64 32)
LANGFUSE_SALT=$(openssl rand -base64 32)
LANGFUSE_ENCRYPTION_KEY=$(openssl rand -hex 32)
LANGFUSE_PUBLIC_KEY=pk-lf-$(uuidgen | tr '[:upper:]' '[:lower:]')
LANGFUSE_SECRET_KEY=sk-lf-$(uuidgen | tr '[:upper:]' '[:lower:]')
EOF

echo
echo "Si cambias LANGFUSE_PUBLIC_KEY/SECRET_KEY o ENCRYPTION_KEY con datos ya escritos," >&2
echo "haz 'make reset' para reprovisionar Langfuse desde cero." >&2
