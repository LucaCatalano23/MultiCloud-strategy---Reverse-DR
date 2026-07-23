from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class TicketSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, case_sensitive=False, extra="ignore")

    database_url: str = Field(min_length=1)
    oidc_issuer_url: str = Field(min_length=1)
    oidc_audience: str = Field(min_length=1)
    oidc_jwks_url: str = Field(min_length=1)
    oidc_roles_claim: str = "roles"
    oidc_required_algorithms: str = "RS256"
    database_pool_min_size: int = Field(default=1, ge=1, le=20)
    database_pool_max_size: int = Field(default=10, ge=1, le=100)

    @property
    def algorithms(self) -> tuple[str, ...]:
        return tuple(item.strip() for item in self.oidc_required_algorithms.split(",") if item.strip())
