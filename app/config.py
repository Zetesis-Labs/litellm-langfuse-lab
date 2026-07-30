from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    litellm_base_url: str = "http://litellm:4000"
    litellm_api_key: str = "sk-lab-master-key"
    default_model: str = "mock"
    request_timeout_seconds: float = 300.0

    langfuse_base_url: str = "http://langfuse-web:3000"
    langfuse_public_url: str = "http://localhost:3100"
    langfuse_project_id: str = "lab"
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""
    langfuse_tracing_environment: str = "development"
    langfuse_flush_at: int = 1

    @property
    def tracing_configured(self) -> bool:
        return bool(self.langfuse_public_key and self.langfuse_secret_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
