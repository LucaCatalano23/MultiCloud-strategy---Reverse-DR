from collections.abc import Mapping

import pytest
from pydantic import ValidationError

from helios_bff.config import BffSettings

CANONICAL_ORIGIN = "https://heliospoc.ggg.it"


def _base_settings(**overrides: object) -> Mapping[str, object]:
    settings: dict[str, object] = {
        "database_url": "postgresql+asyncpg://app:secret@postgres/helios",
        "session_encryption_key": "test-fernet-key",
        "ticket_service_url": "http://ticket-service:8001",
        "automation_service_url": "http://automation-service:8002",
        "application_public_origin": CANONICAL_ORIGIN,
        "oidc_issuer_url": "https://auth.azienda.lan/realms/helios-desk",
        "oidc_audience": "api-client-id-guid",
        "oidc_jwks_url": (
            "http://keycloak.helios-identity.svc.cluster.local:8080/realms/helios-desk/"
            "protocol/openid-connect/certs"
        ),
        "oidc_client_id": "helios-bff",
        "oidc_client_secret": "not-a-real-secret",
        "oidc_authorization_endpoint": (
            "https://auth.azienda.lan/realms/helios-desk/protocol/openid-connect/auth"
        ),
        "oidc_token_endpoint": (
            "http://keycloak.helios-identity.svc.cluster.local:8080/realms/helios-desk/"
            "protocol/openid-connect/token"
        ),
        "oidc_end_session_endpoint": (
            "https://auth.azienda.lan/realms/helios-desk/protocol/openid-connect/logout"
        ),
        "oidc_redirect_uri": f"{CANONICAL_ORIGIN}/api/v1/auth/callback",
        "oidc_post_logout_redirect_uri": f"{CANONICAL_ORIGIN}/",
        "oidc_scopes": "openid profile email",
        "site_mode": "dr",
        "identity_provider": "keycloak",
        "site_name": "on-prem",
    }
    return {**settings, **overrides}


def _cloud_settings(**overrides: object) -> Mapping[str, object]:
    settings: dict[str, object] = {
        "site_mode": "primary",
        "identity_provider": "entra-id",
        "oidc_client_auth_method": "private_key_jwt",
        "oidc_client_secret": None,
        "oidc_client_private_key": "test-private-key",
        "oidc_client_certificate": "test-certificate",
        "oidc_issuer_url": "https://login.microsoftonline.com/tenant-id/v2.0",
        "oidc_jwks_url": ("https://login.microsoftonline.com/tenant-id/discovery/v2.0/keys"),
        "oidc_authorization_endpoint": (
            "https://login.microsoftonline.com/tenant-id/oauth2/v2.0/authorize"
        ),
        "oidc_token_endpoint": ("https://login.microsoftonline.com/tenant-id/oauth2/v2.0/token"),
        "oidc_end_session_endpoint": (
            "https://login.microsoftonline.com/tenant-id/oauth2/v2.0/logout"
        ),
    }
    return {**_base_settings(), **settings, **overrides}


@pytest.mark.unit
def test_onprem_keycloak_configuration_uses_the_canonical_origin() -> None:
    settings = BffSettings(**_base_settings())  # type: ignore[arg-type]

    assert settings.application_public_origin == CANONICAL_ORIGIN
    assert settings.identity_provider == "keycloak"
    assert settings.oidc_client_auth_method == "client_secret"


@pytest.mark.unit
def test_cloud_entra_configuration_uses_certificate_client_authentication() -> None:
    settings = BffSettings(**_cloud_settings())  # type: ignore[arg-type]

    assert settings.identity_provider == "entra-id"
    assert settings.oidc_client_auth_method == "private_key_jwt"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("field", "value"),
    [
        (
            "oidc_jwks_url",
            "https://evil.example/tenant-id/discovery/v2.0/keys",
        ),
        (
            "oidc_jwks_url",
            "https://login.microsoftonline.com/other-tenant/discovery/v2.0/keys",
        ),
        (
            "oidc_token_endpoint",
            "https://evil.example/tenant-id/oauth2/v2.0/token",
        ),
        (
            "oidc_token_endpoint",
            "https://login.microsoftonline.com/other-tenant/oauth2/v2.0/token",
        ),
    ],
)
def test_entra_rejects_misaligned_token_or_jwks_trust_anchors(
    field: str,
    value: str,
) -> None:
    with pytest.raises(ValidationError):
        BffSettings(**_cloud_settings(**{field: value}))  # type: ignore[arg-type]


@pytest.mark.unit
def test_entra_rejects_a_non_microsoft_provider_even_when_all_hosts_match() -> None:
    with pytest.raises(ValidationError):
        BffSettings(
            **_cloud_settings(
                oidc_issuer_url="https://idp.example.com/tenant-id/v2.0",
                oidc_jwks_url="https://idp.example.com/tenant-id/discovery/v2.0/keys",
                oidc_authorization_endpoint=(
                    "https://idp.example.com/tenant-id/oauth2/v2.0/authorize"
                ),
                oidc_token_endpoint="https://idp.example.com/tenant-id/oauth2/v2.0/token",
                oidc_end_session_endpoint=("https://idp.example.com/tenant-id/oauth2/v2.0/logout"),
            )
        )  # type: ignore[arg-type]


@pytest.mark.unit
def test_entra_rejects_a_multitenant_authority() -> None:
    with pytest.raises(ValidationError):
        BffSettings(
            **_cloud_settings(
                oidc_issuer_url="https://login.microsoftonline.com/common/v2.0",
                oidc_jwks_url=("https://login.microsoftonline.com/common/discovery/v2.0/keys"),
                oidc_authorization_endpoint=(
                    "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
                ),
                oidc_token_endpoint=("https://login.microsoftonline.com/common/oauth2/v2.0/token"),
                oidc_end_session_endpoint=(
                    "https://login.microsoftonline.com/common/oauth2/v2.0/logout"
                ),
            )
        )  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.parametrize("tenant", ["tenant?alias", "tenant#alias", "tenant/alias"])
def test_entra_rejects_a_malformed_tenant_identifier(tenant: str) -> None:
    with pytest.raises(ValidationError):
        BffSettings(
            **_cloud_settings(
                oidc_issuer_url=f"https://login.microsoftonline.com/{tenant}/v2.0",
                oidc_jwks_url=(f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys"),
                oidc_authorization_endpoint=(
                    f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize"
                ),
                oidc_token_endpoint=(
                    f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
                ),
                oidc_end_session_endpoint=(
                    f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout"
                ),
            )
        )  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("oidc_jwks_url", "http://evil.internal/realms/helios-desk/certs"),
        (
            "oidc_token_endpoint",
            "http://evil.internal/realms/helios-desk/protocol/openid-connect/token",
        ),
    ],
)
def test_keycloak_rejects_non_allowlisted_internal_trust_endpoints(
    field: str,
    value: str,
) -> None:
    with pytest.raises(ValidationError):
        BffSettings(**_base_settings(**{field: value}))  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("application_public_origin", "http://heliospoc.ggg.it"),
        ("application_public_origin", "https://heliospoc.ggg.it/app"),
        ("oidc_redirect_uri", "https://evil.example/api/v1/auth/callback"),
        ("oidc_post_logout_redirect_uri", "https://evil.example/"),
        ("oidc_end_session_endpoint", "https://evil.example/logout"),
    ],
)
def test_bff_rejects_insecure_or_cross_origin_browser_urls(field: str, value: str) -> None:
    with pytest.raises(ValidationError):
        BffSettings(**_base_settings(**{field: value}))  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.parametrize("origin", ["https://desk.example.test", "https://127.0.0.1"])
def test_bff_rejects_a_noncanonical_origin_even_when_redirects_match(origin: str) -> None:
    with pytest.raises(ValidationError):
        BffSettings(
            **_base_settings(
                application_public_origin=origin,
                oidc_redirect_uri=f"{origin}/api/v1/auth/callback",
                oidc_post_logout_redirect_uri=f"{origin}/",
            )
        )  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.parametrize(
    ("site_mode", "identity_provider", "client_auth_method"),
    [
        ("primary", "keycloak", "client_secret"),
        ("dr", "entra-id", "private_key_jwt"),
        ("primary", "entra-id", "client_secret"),
        ("dr", "keycloak", "private_key_jwt"),
    ],
)
def test_bff_rejects_provider_or_credential_method_for_the_wrong_site(
    site_mode: str,
    identity_provider: str,
    client_auth_method: str,
) -> None:
    overrides: dict[str, object] = {
        "site_mode": site_mode,
        "identity_provider": identity_provider,
        "oidc_client_auth_method": client_auth_method,
    }
    if client_auth_method == "private_key_jwt":
        overrides.update(
            oidc_client_private_key="test-private-key",
            oidc_client_certificate="test-certificate",
        )

    with pytest.raises(ValidationError):
        BffSettings(**_base_settings(**overrides))  # type: ignore[arg-type]
