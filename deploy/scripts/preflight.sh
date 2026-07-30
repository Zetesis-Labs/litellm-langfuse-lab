#!/usr/bin/env bash
set -euo pipefail

# Comprueba lo imprescindible antes de tocar el cluster.

NAMESPACE="${NAMESPACE:-llm-platform}"
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
FAILED=0

printf '\033[1mHerramientas\033[0m\n'
for tool in kubectl helm; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else bad "$tool no encontrado"; fi
done

printf '\n\033[1mCluster\033[0m\n'
if kubectl cluster-info >/dev/null 2>&1; then
  ok "conectado a $(kubectl config current-context)"
else
  bad "kubectl no puede hablar con ningún cluster (revisa el contexto)"
fi

if kubectl get ingressclass >/dev/null 2>&1 && [ -n "$(kubectl get ingressclass -o name 2>/dev/null)" ]; then
  ok "IngressClass: $(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}')"
else
  warn "sin IngressClass: los Ingress se crearán pero no recibirán dirección"
fi

printf '\n\033[1mNamespace y secretos\033[0m\n'
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace $NAMESPACE"
  for secret in langfuse-secrets langfuse-init litellm-secrets litellm-db; do
    if kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
      ok "secret $secret"
    else
      bad "falta el secret $secret (ejecuta deploy/scripts/gen-secrets.sh)"
    fi
  done
else
  bad "el namespace $NAMESPACE no existe: ejecuta antes deploy/scripts/gen-secrets.sh"
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf '\033[31mFaltan cosas obligatorias.\033[0m\n'
  exit 1
fi
printf '\033[32mListo para desplegar.\033[0m\n'
