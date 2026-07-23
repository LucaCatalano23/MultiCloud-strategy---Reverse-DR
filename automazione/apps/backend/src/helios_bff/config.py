from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class BffSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, case_sensitive=False, extra="ignore")

    database_url: str = Field(min_length=1)
    session_encryption_key: SecretStr
    ticket_service_url: str = Field(min_length=1)
    automation_service_url: str = Field(min_length=1)
    oidc_issuer_url: str = Field(min_length=1)
    oidc_audience: str = Field(min_length=1)
    oidc_jwks_url: str = Field(min_length=1)
    oidc_roles_claim: str = "roles"
    oidc_required_algorithms: str = "RS256"
    oidc_client_id: str = Field(min_length=1)
    oidc_client_secret: SecretStr
    oidc_authorization_endpoint: str = Field(min_length=1)
    oidc_token_endpoint: str = Field(min_length=1)
    oidc_redirect_uri: str = Field(min_length=1)
    oidc_post_logout_redirect_uri: str = Field(min_length=1)
    oidc_scopes: str = Field(min_length=1)
    site_mode: Literal["primary", "dr"]
    identity_provider: Literal["entra-id", "keycloak"]
    site_name: str = Field(min_length=1, max_length=120)
    rpo_minutes: int = Field(default=0, ge=0)
    rpo_target_minutes: int = Field(default=10, ge=0)
    database_pool_min_size: int = Field(default=1, ge=1, le=20)
    database_pool_max_size: int = Field(default=10, ge=1, le=100)

    @property
    def algorithms(self) -> tuple[str, ...]:
        return tuple(item.strip() for item in self.oidc_required_algorithms.split(",") if item.strip())

    @property
    def scopes(self) -> tuple[str, ...]:
        return tuple(item for item in self.oidc_scopes.split() if item)
