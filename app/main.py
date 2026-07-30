from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI

from app.config import get_settings
from app.gateway import LiteLLMGateway
from app.langfuse_api import LangfuseReader
from app.observability import Tracer, build_langfuse
from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    tracer = Tracer(build_langfuse(settings))

    async with (
        httpx.AsyncClient(
            base_url=settings.litellm_base_url,
            headers={"Authorization": f"Bearer {settings.litellm_api_key}"},
            timeout=settings.request_timeout_seconds,
        ) as litellm_client,
        httpx.AsyncClient(
            base_url=settings.langfuse_base_url,
            auth=(settings.langfuse_public_key, settings.langfuse_secret_key),
            timeout=30.0,
        ) as langfuse_client,
    ):
        app.state.gateway = LiteLLMGateway(litellm_client)
        app.state.langfuse = LangfuseReader(langfuse_client)
        app.state.tracer = tracer
        try:
            yield
        finally:
            tracer.shutdown()


app = FastAPI(
    title="LLM Observability Lab",
    description=(
        "FastAPI que consume modelos a través de LiteLLM y registra cada llamada "
        "en Langfuse con el coste real que calcula el proxy."
    ),
    version="0.1.0",
    lifespan=lifespan,
)
app.include_router(router)
