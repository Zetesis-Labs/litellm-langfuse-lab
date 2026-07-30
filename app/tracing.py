from langfuse import Langfuse

from app.config import Settings


def new_trace_id() -> str:
    return Langfuse.create_trace_id()


def trace_url(settings: Settings, trace_id: str) -> str:
    base = settings.langfuse_public_url.rstrip("/")
    return f"{base}/project/{settings.langfuse_project_id}/traces/{trace_id}"
