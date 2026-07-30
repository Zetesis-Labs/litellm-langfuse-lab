from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request

from app.config import Settings, get_settings
from app.gateway import GatewayError, LiteLLMGateway
from app.langfuse_api import LangfuseReader, summarize_trace
from app.observability import Tracer, TraceRequest
from app.schemas import AskRequest, AskResponse, HealthResponse, TokenUsage
from app.tracing import new_trace_id, trace_url

router = APIRouter()


def get_gateway(request: Request) -> LiteLLMGateway:
    return request.app.state.gateway


def get_tracer(request: Request) -> Tracer:
    return request.app.state.tracer


def get_langfuse(request: Request) -> LangfuseReader:
    return request.app.state.langfuse


GatewayDep = Annotated[LiteLLMGateway, Depends(get_gateway)]
TracerDep = Annotated[Tracer, Depends(get_tracer)]
LangfuseDep = Annotated[LangfuseReader, Depends(get_langfuse)]
SettingsDep = Annotated[Settings, Depends(get_settings)]


def _build_messages(payload: AskRequest) -> list[dict[str, str]]:
    messages: list[dict[str, str]] = []
    if payload.system:
        messages.append({"role": "system", "content": payload.system})
    messages.append({"role": "user", "content": payload.prompt})
    return messages


def _date_params(start_date: str | None, end_date: str | None) -> dict[str, str]:
    return {k: v for k, v in {"start_date": start_date, "end_date": end_date}.items() if v}


@router.get("/healthz", response_model=HealthResponse)
async def healthz(gateway: GatewayDep, langfuse: LangfuseDep, tracer: TracerDep) -> HealthResponse:
    return HealthResponse(
        api="ok",
        litellm=await gateway.liveness(),
        langfuse=await langfuse.health(),
        tracing="enabled" if tracer.enabled else "disabled",
    )


@router.get("/models")
async def list_models(gateway: GatewayDep) -> dict[str, list[str]]:
    try:
        return {"models": await gateway.models()}
    except GatewayError as exc:
        raise HTTPException(exc.status_code, exc.detail) from exc


@router.post("/ask", response_model=AskResponse)
async def ask(
    payload: AskRequest, gateway: GatewayDep, tracer: TracerDep, settings: SettingsDep
) -> AskResponse:
    model = payload.model or settings.default_model
    messages = _build_messages(payload)
    trace_request = TraceRequest(
        trace_id=new_trace_id(),
        name="ask",
        model=model,
        messages=messages,
        max_tokens=payload.max_tokens,
        session_id=payload.session_id,
        user_id=payload.user_id,
        tags=payload.tags,
    )

    try:
        with tracer.generation(trace_request) as record:
            result = await gateway.chat(
                model=model,
                messages=messages,
                max_tokens=payload.max_tokens,
                trace_id=trace_request.trace_id,
            )
            record(result)
    except GatewayError as exc:
        raise HTTPException(
            exc.status_code,
            {
                "error": exc.detail,
                "trace_id": trace_request.trace_id,
                "langfuse_trace_url": trace_url(settings, trace_request.trace_id),
            },
        ) from exc

    return AskResponse(
        answer=result.answer,
        model=result.model,
        usage=TokenUsage(**{k: v for k, v in result.usage.items() if k in TokenUsage.model_fields}),
        cost_usd=result.cost_usd,
        trace_id=trace_request.trace_id,
        langfuse_trace_url=trace_url(settings, trace_request.trace_id),
        key_spend_usd=result.key_spend_usd,
    )


@router.get("/traces/{trace_id}")
async def read_trace(trace_id: str, langfuse: LangfuseDep) -> dict[str, Any]:
    try:
        observations = await langfuse.observations(trace_id)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(exc.response.status_code, exc.response.text[:2000]) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"Langfuse unreachable: {exc}") from exc
    return summarize_trace(trace_id, observations)


@router.get("/spend/summary")
async def spend_summary(
    gateway: GatewayDep,
    start_date: Annotated[str | None, Query()] = None,
    end_date: Annotated[str | None, Query()] = None,
) -> Any:
    try:
        return await gateway.spend_logs(_date_params(start_date, end_date))
    except GatewayError as exc:
        raise HTTPException(exc.status_code, exc.detail) from exc


@router.get("/spend/detail")
async def spend_detail(
    gateway: GatewayDep,
    start_date: Annotated[str | None, Query()] = None,
    end_date: Annotated[str | None, Query()] = None,
) -> Any:
    params: dict[str, Any] = {"summarize": "false", **_date_params(start_date, end_date)}
    try:
        return await gateway.spend_logs(params)
    except GatewayError as exc:
        raise HTTPException(exc.status_code, exc.detail) from exc


@router.get("/spend/by-key")
async def spend_by_key(gateway: GatewayDep) -> Any:
    try:
        return await gateway.spend_by_key()
    except GatewayError as exc:
        raise HTTPException(exc.status_code, exc.detail) from exc


@router.get("/spend/current-key")
async def spend_current_key(gateway: GatewayDep) -> Any:
    try:
        return await gateway.key_info()
    except GatewayError as exc:
        if exc.status_code == 404:
            return {
                "detail": (
                    "La clave en uso es el master key del proxy, que no tiene presupuesto "
                    "ni gasto propio. Crea una virtual key con 'make key A=<alias> B=<usd>' "
                    "y apunta LITELLM_API_KEY a ella para atribuir gasto por consumidor."
                )
            }
        raise HTTPException(exc.status_code, exc.detail) from exc
