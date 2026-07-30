from pydantic import BaseModel, Field


class AskRequest(BaseModel):
    prompt: str = Field(min_length=1)
    model: str | None = None
    system: str | None = None
    session_id: str | None = None
    user_id: str | None = None
    tags: list[str] = Field(default_factory=list)
    max_tokens: int = Field(default=1024, ge=1, le=128_000)


class TokenUsage(BaseModel):
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None


class AskResponse(BaseModel):
    answer: str
    model: str
    usage: TokenUsage
    cost_usd: float | None
    trace_id: str
    langfuse_trace_url: str
    key_spend_usd: float | None = None


class HealthResponse(BaseModel):
    api: str
    litellm: str
    langfuse: str
    tracing: str
