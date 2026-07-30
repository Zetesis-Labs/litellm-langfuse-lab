#!/usr/bin/env bash
set -euo pipefail

# Despliega Langfuse y LiteLLM en el cluster activo.
#   ./deploy/scripts/apply.sh [namespace]
# Variables: DRY_RUN=1 para renderizar sin aplicar, SKIP_PREFLIGHT=1 para saltar comprobaciones.

NAMESPACE="${1:-${NAMESPACE:-llm-platform}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LANGFUSE_CHART_VERSION="${LANGFUSE_CHART_VERSION:-1.5.41}"
LITELLM_CHART_VERSION="${LITELLM_CHART_VERSION:-1.89.2}"
LANGFUSE_VALUES="${LANGFUSE_VALUES:-$HERE/values/langfuse-aws.yaml}"
LITELLM_VALUES="${LITELLM_VALUES:-$HERE/values/litellm-aws.yaml}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  NAMESPACE="$NAMESPACE" "$HERE/scripts/preflight.sh"
fi

HELM_ARGS=(--namespace "$NAMESPACE" --create-namespace --wait --timeout 15m)
if [ "${DRY_RUN:-0}" = "1" ]; then
  HELM_ARGS+=(--dry-run)
  echo "(DRY_RUN: no se aplicará nada)"
fi

step "Repositorio de Helm de Langfuse"
helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null
helm repo update langfuse >/dev/null

step "Langfuse $LANGFUSE_CHART_VERSION"
helm upgrade --install langfuse langfuse/langfuse \
  --version "$LANGFUSE_CHART_VERSION" \
  -f "$LANGFUSE_VALUES" \
  "${HELM_ARGS[@]}"

step "LiteLLM $LITELLM_CHART_VERSION"
# El chart de LiteLLM se publica solo como artefacto OCI. Si ghcr.io responde 403
# al descargarlo (ocurre con pulls anónimos), autentícate una vez con un PAT de
# GitHub con permiso read:packages:
#   helm registry login ghcr.io -u <usuario> -p <token>
# o exporta LITELLM_CHART_PATH apuntando a una copia local del chart
# (helm/litellm-helm del repositorio BerriAI/litellm).
LITELLM_CHART="${LITELLM_CHART_PATH:-oci://ghcr.io/berriai/litellm-helm}"
LITELLM_VERSION_ARG=(--version "$LITELLM_CHART_VERSION")
[ -n "${LITELLM_CHART_PATH:-}" ] && LITELLM_VERSION_ARG=()

helm upgrade --install litellm "$LITELLM_CHART" \
  "${LITELLM_VERSION_ARG[@]}" \
  -f "$LITELLM_VALUES" \
  "${HELM_ARGS[@]}"

if [ "${DRY_RUN:-0}" = "1" ]; then
  exit 0
fi

step "Estado"
kubectl -n "$NAMESPACE" get deploy,svc,ingress

cat <<EOF

Siguientes pasos:
  1. Espera a que el ALB tenga dirección:
       kubectl -n $NAMESPACE get ingress -w
  2. Entra en Langfuse con el usuario provisionado y comprueba que el proyecto existe.
  3. Apunta tu aplicación al proxy y a Langfuse:
       LITELLM_BASE_URL=http://litellm.$NAMESPACE.svc.cluster.local:4000
       LANGFUSE_BASE_URL=http://langfuse-web.$NAMESPACE.svc.cluster.local:3000
  4. Verifica el gasto:
       kubectl -n $NAMESPACE exec deploy/litellm -- \\
         curl -sS localhost:4000/spend/logs -H "Authorization: Bearer \$PROXY_MASTER_KEY"
EOF
