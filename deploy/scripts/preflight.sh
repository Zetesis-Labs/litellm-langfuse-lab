#!/usr/bin/env bash
set -euo pipefail

# Comprueba que el entorno puede desplegar antes de tocar el cluster.

NAMESPACE="${NAMESPACE:-llm-platform}"
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
FAILED=0

printf '\033[1mHerramientas\033[0m\n'
for tool in kubectl helm; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool disponible"; else bad "$tool no encontrado"; fi
done

printf '\n\033[1mCluster\033[0m\n'
if kubectl cluster-info >/dev/null 2>&1; then
  ok "conectado a $(kubectl config current-context)"
else
  bad "kubectl no puede hablar con ningún cluster (revisa el contexto)"
fi

printf '\n\033[1mDependencias del cluster\033[0m\n'
if kubectl get crd 2>/dev/null | grep -q 'clusters.postgresql.cnpg.io'; then
  ok "CloudNativePG instalado (perfil in-cluster disponible)"
else
  warn "CloudNativePG ausente: usa RDS/ElastiCache (values-aws.yaml) o instálalo"
fi

if kubectl get crd 2>/dev/null | grep -q 'externalsecrets.external-secrets.io'; then
  ok "External Secrets Operator instalado"
else
  warn "External Secrets ausente: los secretos habrá que crearlos a mano"
fi

if kubectl get ingressclass 2>/dev/null | grep -qE 'alb|nginx'; then
  ok "IngressClass disponible: $(kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
else
  warn "sin IngressClass: los Ingress quedarán sin dirección asignada"
fi

if kubectl get storageclass 2>/dev/null | grep -q .; then
  ok "StorageClass por defecto: $(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || echo '(ninguna marcada)')"
else
  warn "sin StorageClass: ClickHouse y Postgres in-cluster no podrán arrancar"
fi

printf '\n\033[1mNamespace y secretos\033[0m\n'
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace $NAMESPACE existe"
  for secret in langfuse-secrets litellm-secrets; do
    if kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
      ok "secret $secret presente"
    else
      bad "falta el secret $secret (ver deploy/README.md)"
    fi
  done
else
  warn "namespace $NAMESPACE no existe todavía (lo crea apply.sh)"
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf '\033[31mHay comprobaciones obligatorias sin pasar.\033[0m\n'
  exit 1
fi
printf '\033[32mListo para desplegar.\033[0m\n'
