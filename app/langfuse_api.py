from typing import Any

import httpx

_OBSERVATION_FIELDS = "core,basic,usage,model,trace_context,metrics"


class LangfuseReader:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client

    async def health(self) -> str:
        try:
            response = await self._client.get("/api/public/health")
        except httpx.HTTPError as exc:
            return f"unreachable: {exc}"
        if response.is_error:
            return f"unhealthy ({response.status_code})"
        return response.json().get("status", "unknown")

    async def observations(self, trace_id: str) -> list[dict[str, Any]]:
        params = {"traceId": trace_id, "fields": _OBSERVATION_FIELDS, "limit": 100}
        response = await self._client.get("/api/public/v2/observations", params=params)
        response.raise_for_status()
        return response.json().get("data", [])


def summarize_trace(trace_id: str, observations: list[dict[str, Any]]) -> dict[str, Any]:
    total_cost = sum(float(item.get("totalCost") or 0.0) for item in observations)
    generations = [item for item in observations if item.get("type") == "GENERATION"]
    first = observations[0] if observations else {}

    return {
        "trace_id": trace_id,
        "ingested": bool(observations),
        "observations": len(observations),
        "total_cost_usd": total_cost if observations else None,
        "session_id": first.get("sessionId") or None,
        "user_id": first.get("userId") or None,
        "tags": first.get("tags") or [],
        "generations": [
            {
                "name": item.get("name"),
                "model": item.get("model") or item.get("providedModelName"),
                "total_cost_usd": item.get("totalCost"),
                "cost_details": item.get("costDetails"),
                "usage_details": item.get("usageDetails"),
                "latency_seconds": item.get("latency"),
            }
            for item in generations
        ],
    }
