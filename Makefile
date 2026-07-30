SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

.PHONY: help up down logs ps smoke secrets key reset build shell

help: ## Muestra esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Arranca el stack completo
	$(COMPOSE) up -d --build
	@echo
	@echo "Langfuse:  http://localhost:$${LANGFUSE_PORT:-3100}"
	@echo "LiteLLM:   http://localhost:$${LITELLM_PORT:-4000}"
	@echo "FastAPI:   http://localhost:$${API_PORT:-8000}/docs"

down: ## Para el stack (conserva los volúmenes)
	$(COMPOSE) down

reset: ## Para el stack y BORRA todos los datos
	$(COMPOSE) down -v

logs: ## Sigue los logs (make logs S=litellm para un servicio)
	$(COMPOSE) logs -f $(S)

ps: ## Estado de los servicios
	$(COMPOSE) ps

build: ## Reconstruye la imagen de la API
	$(COMPOSE) build api

shell: ## Abre una shell en el contenedor de la API
	$(COMPOSE) exec api bash

smoke: ## Valida el camino completo (make smoke M=claude-sonnet-5)
	./scripts/smoke.sh $(or $(M),mock)

secrets: ## Genera secretos nuevos para .env
	./scripts/gen-secrets.sh

key: ## Crea una virtual key con presupuesto (make key A=equipo-datos B=10)
	./scripts/new-key.sh $(or $(A),demo) $(or $(B),5)
