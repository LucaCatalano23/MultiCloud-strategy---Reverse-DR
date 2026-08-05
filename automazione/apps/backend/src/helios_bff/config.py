import re
from collections.abc import Mapping
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

CANONICAL_APPLICATION_ORIGIN = "https://heliospoc.ggg.it"
ENTRA_AUTHORITY = "https://login.microsoftonline.com"
ENTRA_MULTITENANT_AUTHORITIES = frozenset({"common", "organizations", "consumers"})
KEYCLOAK_PUBLIC_REALM = "https://auth.azienda.lan/realms/helios-desk"
KEYCLOAK_INTERNAL_REALM = (
    "http://keycloak.helios-identity.svc.cluster.local:8080/realms/helios-desk"
)


def _require_exact_endpoints(
    settings: "BffSettings",
    expected: Mapping[str, str],
    *,
    provider: str,
) -> None:
    for field_name, expected_value in expected.items():
        if getattr(settings, field_name) != expected_value:
            raise ValueError(f"{field_name.upper()} does not match the {provider} trust profile")


def _validate_entra_trust_profile(settings: "BffSettings") -> None:
    issuer_prefix = f"{ENTRA_AUTHORITY}/"
    issuer_suffix = "/v2.0"
    issuer = settings.oidc_issuer_url
    if not issuer.startswith(issuer_prefix) or not issuer.endswith(issuer_suffix):
        raise ValueError("OIDC_ISSUER_URL must use the tenant-specific Entra v2 authority")
    tenant = issuer[len(issuer_prefix) : -len(issuer_suffix)]
    is_valid_tenant = re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?",
        tenant,
    )
    if is_valid_tenant is None or tenant.lower() in ENTRA_MULTITENANT_AUTHORITIES:
        raise ValueError("OIDC_ISSUER_URL must identify one Entra tenant")
    tenant_authority = f"{ENTRA_AUTHORITY}/{tenant}"
    _require_exact_endpoints(
        settings,
        {
            "oidc_authorization_endpoint": f"{tenant_authority}/oauth2/v2.0/authorize",
            "oidc_token_endpoint": f"{tenant_authority}/oauth2/v2.0/token",
            "oidc_end_session_endpoint": f"{tenant_authority}/oauth2/v2.0/logout",
            "oidc_jwks_url": f"{tenant_authority}/discovery/v2.0/keys",
        },
        provider="Entra tenant",
    )


def _validate_keycloak_trust_profile(settings: "BffSettings") -> None:
    _require_exact_endpoints(
        settings,
        {
            "oidc_issuer_url": KEYCLOAK_PUBLIC_REALM,
            "oidc_authorization_endpoint": (
                f"{KEYCLOAK_PUBLIC_REALM}/protocol/openid-connect/auth"
            ),
            "oidc_end_session_endpoint": (
                f"{KEYCLOAK_PUBLIC_REALM}/protocol/openid-connect/logout"
            ),
            "oidc_token_endpoint": (f"{KEYCLOAK_INTERNAL_REALM}/protocol/openid-connect/token"),
            "oidc_jwks_url": f"{KEYCLOAK_INTERNAL_REALM}/protocol/openid-connect/certs",
        },
        provider="LXCLab Keycloak realm",
    )


class BffSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, case_sensitive=False, extra="ignore")

    database_url: str = Field(min_length=1)
    session_encryption_key: SecretStr
    ticket_service_url: str = Field(min_length=1)
    automation_service_url: str = Field(min_length=1)
    application_public_origin: str = Field(min_length=1)
    oidc_issuer_url: str = Field(min_length=1)
    oidc_audience: str = Field(min_length=1)
    oidc_jwks_url: str = Field(min_length=1)
    oidc_roles_claim: str = "roles"
    oidc_required_algorithms: str = "RS256"
    oidc_client_id: str = Field(min_length=1)
    # Come il BFF si autentica sul token endpoint. Il primario Entra impone
    # `private_key_jwt` perche' la policy del tenant vieta i client secret; il
    # DR Keycloak resta su `client_secret`. E' configurazione per sito, non un
    # branch nel codice: vedi infrastructure/oidc_client_credentials.py.
    oidc_client_auth_method: Literal["client_secret", "private_key_jwt"] = "client_secret"
    oidc_client_secret: SecretStr | None = None
    oidc_client_private_key: SecretStr | None = None
    oidc_client_certificate: str | None = None
    oidc_authorization_endpoint: str = Field(min_length=1)
    oidc_token_endpoint: str = Field(min_length=1)
    oidc_end_session_endpoint: str = Field(min_length=1)
    oidc_redirect_uri: str = Field(min_length=1)
    oidc_post_logout_redirect_uri: str = Field(min_length=1)
    oidc_scopes: str = Field(min_length=1)
    site_mode: Literal["primary", "dr"]
    identity_provider: Literal["entra-id", "keycloak"]
    site_name: str = Field(min_length=1, max_length=120)
    # Solo gli OBIETTIVI sono configurabili. I valori misurati (eta' dell'ultimo
    # backup, durata dell'ultimo failover) arrivano dalla tabella `dr_telemetry`
    # scritta da chi ha eseguito l'operazione: non esiste piu' un `RPO_MINUTES`
    # deciso a mano e mostrato in UI come se fosse una misura.
    # Default: 900s = 15' perche' il CronJob di backup gira ogni 10' e un ciclo
    # perso deve restare "ok"; 1800s = 30' e' l'RTO dichiarato per il playbook.
    rpo_target_seconds: int = Field(default=900, ge=1)
    rto_target_seconds: int = Field(default=1800, ge=1)
    database_pool_min_size: int = Field(default=1, ge=1, le=20)
    database_pool_max_size: int = Field(default=10, ge=1, le=100)

    @model_validator(mode="after")
    def _client_credential_is_complete(self) -> "BffSettings":
        """Fallisce all'avvio, non al primo login.

        Una credenziale incompleta e' un errore di deployment: scoprirlo quando
        un utente prova ad autenticarsi significa un 500 opaco in produzione
        invece di un pod che non parte.
        """
        if self.oidc_client_auth_method == "client_secret":
            if self.oidc_client_secret is None:
                raise ValueError("OIDC_CLIENT_SECRET is required when auth method is client_secret")
        elif self.oidc_client_private_key is None or not self.oidc_client_certificate:
            raise ValueError(
                "OIDC_CLIENT_PRIVATE_KEY and OIDC_CLIENT_CERTIFICATE are required "
                "when auth method is private_key_jwt"
            )

        expected_profile = {
            "primary": ("entra-id", "private_key_jwt"),
            "dr": ("keycloak", "client_secret"),
        }[self.site_mode]
        actual_profile = (self.identity_provider, self.oidc_client_auth_method)
        if actual_profile != expected_profile:
            raise ValueError(
                "identity provider and OIDC client authentication method do not match the site"
            )

        origin = urlsplit(self.application_public_origin)
        if (
            origin.scheme != "https"
            or not origin.hostname
            or origin.username is not None
            or origin.password is not None
            or origin.path not in ("", "/")
            or origin.query
            or origin.fragment
        ):
            raise ValueError("APPLICATION_PUBLIC_ORIGIN must be an HTTPS origin without a path")
        normalized_origin = self.application_public_origin.rstrip("/")
        if self.application_public_origin != normalized_origin:
            raise ValueError("APPLICATION_PUBLIC_ORIGIN must not have a trailing slash")
        if normalized_origin != CANONICAL_APPLICATION_ORIGIN:
            raise ValueError(f"APPLICATION_PUBLIC_ORIGIN must be {CANONICAL_APPLICATION_ORIGIN}")
        expected_callback = f"{normalized_origin}/api/v1/auth/callback"
        if self.oidc_redirect_uri != expected_callback:
            raise ValueError("OIDC_REDIRECT_URI must use the canonical application origin")
        if self.oidc_post_logout_redirect_uri != f"{normalized_origin}/":
            raise ValueError(
                "OIDC_POST_LOGOUT_REDIRECT_URI must use the canonical application origin"
            )
        if self.identity_provider == "entra-id":
            _validate_entra_trust_profile(self)
        else:
            _validate_keycloak_trust_profile(self)
        return self

    @property
    def algorithms(self) -> tuple[str, ...]:
        return tuple(
            item.strip() for item in self.oidc_required_algorithms.split(",") if item.strip()
        )

    @property
    def scopes(self) -> tuple[str, ...]:
        return tuple(item for item in self.oidc_scopes.split() if item)
