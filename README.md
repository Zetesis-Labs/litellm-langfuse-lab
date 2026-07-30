# LLM Observability Lab

[![CI](https://github.com/Zetesis-Labs/litellm-langfuse-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/Zetesis-Labs/litellm-langfuse-lab/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Devcontainer con **LiteLLM** (gateway de modelos) y **Langfuse v4** (observabilidad) conectados
entre sí, y una **FastAPI** que los consume para hacer consultas a modelos con trazabilidad del
gasto real.

```
FastAPI  ──HTTP──▶  LiteLLM proxy  ──▶  Anthropic / OpenAI / DeepInfra
   │                     │
   │                     └── calcula el coste y lo devuelve en x-litellm-response-cost
   │                          y lo persiste en Postgres (/spend/logs, budgets por key)
   │
   └──SDK Langfuse v4──▶  Langfuse  (traza con coste, tokens, sesión, usuario y etiquetas)
```

## Arranque

```bash
cp .env.example .env      # opcional: sin .env arranca igual, pero solo responde el modelo `mock`
make up
make smoke                # valida el camino completo de punta a punta
```

| Servicio | URL | Credenciales |
|---|---|---|
| FastAPI (Swagger) | http://localhost:8000/docs | — |
| Langfuse | http://localhost:3100 | `lab@example.com` / `labpassword` |
| LiteLLM (Swagger) | http://localhost:4000 | master key de `.env` |
| MinIO (consola) | http://localhost:9191 | `minio` / `miniosecret` |

`make smoke` hace una consulta, muestra el coste calculado, espera a que Langfuse la ingiera y
te devuelve el gasto ya registrado allí. Si eso pasa, el stack está bien conectado.

## Usar modelos reales

Pon la clave del proveedor en `.env` (`ANTHROPIC_API_KEY=...`), `make up` para recargar, y:

```bash
make smoke M=claude-sonnet-5
```

Modelos publicados en `litellm/config.yaml`: `mock`, `claude-opus-5`, `claude-sonnet-5`,
`claude-haiku-4-5`, `gpt-4o`. Añadir uno es una entrada más en `model_list`.

El modelo `mock` no llama a ningún proveedor y **no necesita clave**, pero lleva precios
declarados: recorre exactamente el mismo camino de coste que un modelo real, así que sirve para
validar el pipeline sin gastar dinero.

## Endpoints de la API

| Endpoint | Para qué |
|---|---|
| `POST /ask` | Consulta un modelo. Devuelve respuesta, tokens, **coste en USD**, `trace_id` y el enlace a la traza |
| `GET /traces/{trace_id}` | Lee de vuelta desde Langfuse el gasto y los metadatos de esa traza |
| `GET /models` | Modelos que publica el proxy |
| `GET /spend/summary` | Gasto agregado (`/spend/logs` de LiteLLM) |
| `GET /spend/detail` | Una fila por llamada |
| `GET /spend/by-key` | Gasto por virtual key |
| `GET /healthz` | Estado de la API, del proxy y de Langfuse |

```bash
curl -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{
  "prompt": "Resume la teoría de juegos en una frase",
  "model": "claude-sonnet-5",
  "session_id": "conversacion-42",
  "user_id": "ruben",
  "tags": ["demo"]
}'
```

`session_id`, `user_id` y `tags` se propagan a Langfuse, que agrega el gasto por sesión y por
usuario en su UI.

## Atribuir gasto por consumidor

Por defecto la API usa el master key del proxy, que no tiene presupuesto propio. Para atribuir
gasto y poner topes por consumidor, crea virtual keys:

```bash
make key A=equipo-datos B=10     # alias equipo-datos, tope de 10 USD / 30 días
```

Apunta `LITELLM_API_KEY` a la clave devuelta y su gasto aparecerá en `/spend/by-key`. Al superar
`max_budget` LiteLLM rechaza las llamadas.

## Comandos

```bash
make up        # arranca (o recarga) el stack
make smoke     # prueba de punta a punta      (make smoke M=claude-sonnet-5)
make logs      # sigue los logs               (make logs S=litellm)
make key       # crea una virtual key         (make key A=alias B=presupuesto)
make secrets   # genera secretos para .env
make down      # para el stack, conserva los datos
make reset     # para el stack y BORRA los datos
```

## Devcontainer

`.devcontainer/` reutiliza el mismo `docker-compose.yml`; el servicio `api` se abre como
contenedor de desarrollo con el código montado en `/workspace`. Al abrirlo en VS Code, el
servicio arranca con `sleep infinity` en lugar de uvicorn, así que el servidor lo lanzas tú:

```bash
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Fuera del devcontainer, `make up` arranca uvicorn automáticamente con recarga en caliente.

## Decisiones que conviene conocer

**Quién emite las trazas.** Las emite la FastAPI con el SDK de Langfuse v4, no LiteLLM. Los dos
callbacks de LiteLLM fallan contra Langfuse v4:

- `success_callback: ["langfuse"]` usa la API de ingesta del SDK v2. Langfuse v4 arranca en modo
  `events_only` y solo acepta ahí eventos de tipo `score` y `log`: todo lo demás vuelve como
  error 400 por evento.
- `callbacks: ["langfuse_otel"]` sí ingiere por OTLP, pero llega sin coste ni `session_id`/
  `user_id`, y arrastra los spans internos del proxy (Postgres, auth) como ruido.

Emitiéndolas desde la aplicación se obtiene el coste real (el que calcula LiteLLM, propagado
como `cost_details`), los metadatos de negocio y una única observación limpia por llamada.
LiteLLM sigue siendo la fuente de verdad del gasto: `/spend/logs` y los presupuestos por key.

El `trace_id` viaja al proxy en la cabecera `x-litellm-trace-id`, de modo que una traza de
Langfuse y su fila en `/spend/logs` se pueden cruzar.

**Si se activara el callback de LiteLLM además del SDK**, habría dos generaciones por llamada y
el gasto se contaría dos veces: `litellm` es un scope reconocido por el SDK de Langfuse.

**Versiones pineadas.** `langfuse/langfuse:4` y `langfuse-worker:4` (la etiqueta `latest` sigue
apuntando a la serie 3), ClickHouse 25.12 (v4 exige 25.12 como mínimo), Postgres 17, Redis 7 con
`noeviction` y `ghcr.io/berriai/litellm-database:v1.94.0` (la variante `-database` es la que trae
Prisma, necesario para el gasto persistido; la etiqueta `main-stable` está deprecada).

**Un solo Postgres** con dos bases, `langfuse` y `litellm`, creadas al inicializar el contenedor.

**Costes a 0.** Si `/spend/summary` muestra `spend: 0.0` para un modelo, LiteLLM no conoce su
precio: declara `input_cost_per_token` / `output_cost_per_token` en su entrada de `model_list`
(hay una plantilla comentada con los precios de Anthropic al final del fichero).

**Secretos.** Los valores por defecto son de desarrollo y están en claro en `docker-compose.yml`.
Para cualquier cosa expuesta, `make secrets` y pégalos en `.env`. Ojo con los formatos que exige
Langfuse: `NEXTAUTH_SECRET` y `SALT` en base64, `ENCRYPTION_KEY` en hex de exactamente 64
caracteres.

## Kubernetes

El despliegue en EKS con los charts oficiales está en [`deploy/README.md`](deploy/README.md).
