from dataclasses import dataclass
from typing import Any

import httpx


class GatewayError(RuntimeError):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


@dataclass(frozen=True)
class ChatResult:
    answer: str
    model: str
    usage: dict[str, Any]
    cost_usd: float | None
    key_spend_usd: float | None
    response_id: str | None


def _float_header(headers: httpx.Headers, name: str) -> float | None:
    raw = headers.get(name)
    if raw is None:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _first_message(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") or []
    if not choices:
        return ""
    return choices[0].get("message", {}).get("content") or ""


class LiteLLMGateway:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            response = await self._client.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise GatewayError(502, f"LiteLLM unreachable: {exc}") from exc
        if response.is_error:
            raise GatewayError(response.status_code, response.text[:2000])
        return response

    async def chat(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        max_tokens: int,
        trace_id: str,
    ) -> ChatResult:
        body = {"model": model, "messages": messages, "max_tokens": max_tokens}
        response = await self._request(
            "POST",
            "/v1/chat/completions",
            json=body,
            headers={"x-litellm-trace-id": trace_id},
        )
        payload = response.json()
        return ChatResult(
            answer=_first_message(payload),
            model=payload.get("model", model),
            usage=payload.get("usage") or {},
            cost_usd=_float_header(response.headers, "x-litellm-response-cost"),
            key_spend_usd=_float_header(response.headers, "x-litellm-key-spend"),
            response_id=payload.get("id"),
        )

    async def models(self) -> list[str]:
        response = await self._request("GET", "/v1/models")
        return sorted(entry["id"] for entry in response.json().get("data", []))

    async def spend_logs(self, params: dict[str, Any]) -> Any:
        response = await self._request("GET", "/spend/logs", params=params)
        return response.json()

    async def spend_by_key(self) -> Any:
        response = await self._request("GET", "/spend/keys")
        return response.json()

    async def key_info(self) -> Any:
        response = await self._request("GET", "/key/info")
        return response.json()

    async def liveness(self) -> str:
        try:
            response = await self._client.get("/health/readiness")
        except httpx.HTTPError as exc:
            return f"unreachable: {exc}"
        if response.is_error:
            return f"unhealthy ({response.status_code})"
        return response.json().get("status", "unknown")
