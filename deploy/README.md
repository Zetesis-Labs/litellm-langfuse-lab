# Despliegue en Kubernetes (EKS)

Los mismos dos componentes del entorno local, con los charts oficiales, apuntando a
dependencias gestionadas de AWS.

```
        ALB (interno)                    ALB (público, ACM)
             │                                   │
        ┌────▼─────┐                      ┌──────▼──────┐
        │ litellm  │                      │ langfuse-web│
        └────┬─────┘                      └──────┬──────┘
             │                            ┌──────▼──────┐
             │                            │langfuse-work│
             │                            └──────┬──────┘
             ▼                                   ▼
     RDS (litellm)          RDS (langfuse) · ElastiCache · ClickHouse · S3
```

## Lo que hay que tener antes

Nada de esto lo crean los charts:

| Recurso | Notas |
|---|---|
| Cluster EKS | Con el AWS Load Balancer Controller si vas a usar `className: alb` |
| RDS PostgreSQL ≥ 16 | Dos bases: `langfuse` y `litellm`. Pueden estar en la misma instancia |
| ElastiCache (Redis/Valkey ≥ 7.2) | **Con `maxmemory-policy=noeviction` en el parameter group.** Langfuse lo exige y nada lo comprueba por ti |
| ClickHouse ≥ 25.12 | La pieza incómoda: ver más abajo |
| Bucket de S3 | Para eventos, media y exportaciones |
| Rol de IAM para IRSA | Con acceso al bucket, asumible por el ServiceAccount `langfuse` |
| Certificado en ACM | Para la terminación TLS en el ALB |

## Desplegar

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./deploy/scripts/gen-secrets.sh          # crea el namespace y los Secrets
# edita deploy/values/*.yaml: todo lo marcado con CAMBIAR
DRY_RUN=1 ./deploy/scripts/apply.sh      # renderiza sin aplicar
./deploy/scripts/apply.sh                # aplica
```

`preflight.sh` corre antes y avisa de lo que falta (IngressClass, StorageClass, operadores,
Secrets). Para GitOps, en `argocd/` hay un Application por componente en lugar del script.

## ClickHouse: la decisión importante

Langfuse necesita ClickHouse y **el que empaqueta el chart no sirve para v4** (además es un
subchart de Bitnami). Tres salidas:

1. **ClickHouse Cloud** — es lo que traen configurados los values. Lo más rápido; es un servicio
   externo de pago.
2. **Operador oficial en el cluster** — `helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm`
   (necesita cert-manager). Es la vía que recomienda el propio repositorio del chart para v4, y
   la que deja todo dentro de tu VPC. Luego `clickhouse.host: langfuse-clickhouse-headless`,
   `httpPort: 8123`, `nativePort: 9440` y `migration.ssl: false`.
3. **Quedarte en Langfuse v3** — quita el `tag: "4"` de los values. Entonces el chart despliega
   su ClickHouse de Bitnami y funciona sin más, pero pierdes v4 y el endpoint
   `/api/public/v2/observations` en el que se apoya el endpoint `/traces/{id}` de la aplicación.

## Por qué los values son así

**Los cuatro subcharts de Langfuse son de Bitnami** (postgresql, clickhouse, valkey, minio) y van
todos con `deploy: false`, así que no se despliega ninguna imagen de Bitnami. Queda una
dependencia inevitable: la librería `common` de Bitnami no tiene `condition` y `helm dependency`
siempre la descarga. No aporta contenedores, solo plantillas.

**El chart va por detrás del producto.** Chart 1.5.41 tiene `appVersion: 3.224.1`, así que la
imagen se fija a mano con `langfuse.web.image.tag: "4"` y `worker.image.tag: "4"`. Nunca uses
`latest`: sigue resolviendo a la serie 3.

**S3 sin claves.** Dejando `s3.accessKeyId` y `s3.secretAccessKey` vacíos, el chart no emite
ninguna variable `LANGFUSE_S3_*_ACCESS_KEY_ID` y el SDK de AWS cae a la cadena de credenciales,
que con IRSA resuelve al rol del ServiceAccount. No mezcles esto con variables `LANGFUSE_S3_*` en
`additionalEnv`: el chart aborta el render si detecta las dos cosas.

**`postgresql.args`, no `postgresql.auth.args`.** La segunda existe en el `values.yaml` del chart
pero ninguna plantilla la usa, así que un `sslmode=require` puesto ahí se pierde en silencio.

**ElastiCache sin RBAC necesita `redis.auth.username: null`.** Con un usuario en la cadena de
conexión, la conexión falla.

**En LiteLLM el master key se llama `PROXY_MASTER_KEY`.** El chart no conoce `LITELLM_MASTER_KEY`
ni `LITELLM_SALT_KEY`: el primero se referencia con `masterkeySecretName`/`masterkeySecretKey`, y
el salt key entra por `environmentSecrets` junto a las claves de los proveedores. Si dejas
`masterkeySecretName` vacío, el chart genera un master key aleatorio en cada render, que bajo
GitOps significa rotarlo en cada sincronización.

**Las migraciones de LiteLLM ya vienen resueltas para ArgoCD.** El Job usa la misma imagen del
proxy y se anota como `PreSync`; el Deployment recibe `DISABLE_SCHEMA_UPDATE=true` para que las
réplicas no compitan migrando el esquema en cada rollout.

**El ALB no debe apuntar a `/health`.** Ese endpoint hace una llamada real a *cada* modelo
configurado, y con modelos de pago eso cuesta dinero en cada comprobación. Usa
`/health/liveliness`.

## Trampa conocida: 403 al descargar el chart de LiteLLM

El chart solo se publica como artefacto OCI y `helm pull oci://ghcr.io/berriai/litellm-helm`
puede responder `403: denied` en descargas anónimas (reproducido durante la preparación de estos
values, con el listado de tags funcionando y el manifiesto denegado). Dos salidas:

```bash
# a) autenticarse una vez con un PAT de GitHub con read:packages
helm registry login ghcr.io -u <usuario> -p <token>

# b) usar una copia local del chart
curl -sL https://github.com/BerriAI/litellm/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=1 -C /tmp litellm-main/helm
LITELLM_CHART_PATH=/tmp/helm/litellm-helm ./deploy/scripts/apply.sh
```

Ojo con las versiones del chart de LiteLLM: el `Chart.yaml` del repositorio dice `1.1.0`, pero el
CI reescribe la versión al publicar y en el registro la última es `1.89.2`. Fíate del registro,
no del árbol de fuentes.

## Estado de la validación

Ambos charts se renderizan correctamente con estos values (`helm template`), y se ha comprobado
en el manifiesto resultante: imágenes `langfuse:4` y `langfuse-worker:4`, `litellm-database:v1.94.0`,
cero referencias a Bitnami, `DATABASE_ARGS=sslmode=require`, `REDIS_CONNECTION_STRING` con
`rediss://`, `CLICKHOUSE_CLUSTER_ENABLED=false`, ninguna variable de credenciales de S3, la
anotación de IRSA en el ServiceAccount, y el Job de migración con los hooks de ArgoCD.

**No se ha desplegado contra un EKS real**: los endpoints de RDS, ElastiCache, ClickHouse, el
bucket y los ARN son marcadores. Lo que está verificado es que los manifiestos son correctos y
coherentes, no que tu infraestructura responda.
