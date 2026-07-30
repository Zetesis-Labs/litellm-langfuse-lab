import logging
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from functools import partial
from typing import Any

from langfuse import Langfuse, propagate_attributes

from app.config import Settings
from app.gateway import ChatResult, GatewayError

logger = logging.getLogger(__name__)

RecordFn = Callable[[ChatResult], None]

_USAGE_KEYS = {
    "prompt_tokens": "input",
    "completion_tokens": "output",
    "total_tokens": "total",
}


@dataclass(frozen=True)
class TraceRequest:
    trace_id: str
    name: str
    model: str
    messages: list[dict[str, str]]
    max_tokens: int
    session_id: str | None = None
    user_id: str | None = None
    tags: list[str] = field(default_factory=list)


def build_langfuse(settings: Settings) -> Langfuse | None:
    if not settings.tracing_configured:
        logger.warning("Langfuse sin credenciales: las trazas quedan desactivadas")
        return None

    client = Langfuse(
        public_key=settings.langfuse_public_key,
        secret_key=settings.langfuse_secret_key,
        base_url=settings.langfuse_base_url,
        environment=settings.langfuse_tracing_environment,
        flush_at=settings.langfuse_flush_at,
        flush_interval=1.0,
        timeout=10,
    )

    try:
        if not client.auth_check():
            logger.warning("Langfuse rechazó las credenciales; se seguirá intentando en cada traza")
    except Exception as exc:
        logger.warning("Langfuse no responde al arrancar (%s); la API sigue operativa", exc)

    return client


def _usage_details(usage: dict[str, Any]) -> dict[str, int] | None:
    details = {
        target: int(usage[source])
        for source, target in _USAGE_KEYS.items()
        if isinstance(usage.get(source), int | float)
    }
    return details or None


def _trace_attributes(request: TraceRequest) -> dict[str, Any]:
    attributes: dict[str, Any] = {
        "trace_name": request.name,
        "tags": ["lab", *request.tags],
    }
    if request.session_id:
        attributes["session_id"] = request.session_id
    if request.user_id:
        attributes["user_id"] = request.user_id
    return attributes


def _record(generation: Any, result: ChatResult) -> None:
    generation.update(
        output=result.answer,
        model=result.model,
        usage_details=_usage_details(result.usage),
        cost_details={"total": result.cost_usd} if result.cost_usd is not None else None,
        metadata={"litellm_response_id": result.response_id},
    )


def _discard(_: ChatResult) -> None:
    return None


class Tracer:
    def __init__(self, client: Langfuse | None) -> None:
        self._client = client

    @property
    def enabled(self) -> bool:
        return self._client is not None

    def shutdown(self) -> None:
        if self._client is not None:
            self._client.shutdown()

    @contextmanager
    def generation(self, request: TraceRequest) -> Iterator[RecordFn]:
        if self._client is None:
            yield _discard
            return

        with (
            propagate_attributes(**_trace_attributes(request)),
            self._client.start_as_current_observation(
                trace_context={"trace_id": request.trace_id},
                name=request.name,
                as_type="generation",
                input=request.messages,
                model=request.model,
                model_parameters={"max_tokens": request.max_tokens},
            ) as generation,
        ):
            try:
                yield partial(_record, generation)
            except GatewayError as exc:
                generation.update(level="ERROR", status_message=exc.detail[:500])
                raise
