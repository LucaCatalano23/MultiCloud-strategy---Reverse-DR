from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from helios_bff.application.auth_service import BrowserAuthService
from helios_bff.config import BffSettings
from helios_bff.infrastructure.crypto import FernetSecretProtector
from helios_bff.infrastructure.oidc_client import HttpOidcBrowserClient, OidcBrowserConfig
from helios_bff.infrastructure.postgres import PostgresAuthStore
from helios_bff.infrastructure.service_clients import (
    HttpAutomationClient,
    HttpPlatformProbe,
    HttpTicketClient,
)
from helios_bff.infrastructure.telemetry import PostgresDrTelemetryStore
from helios_bff.presentation.api import BffSite, create_app
from helios_shared.oidc import OidcJwtAuthenticator, OidcVerificationConfig, PyJwkSigningKeyProvider


def build_app() -> FastAPI:
    settings = BffSettings()  # type: ignore[call-arg]
    pool = AsyncConnectionPool(
        conninfo=settings.database_url,
        min_size=settings.database_pool_min_size,
        max_size=settings.database_pool_max_size,
        open=False,
        kwargs={"row_factory": dict_row},
    )
    http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(10.0, connect=2.0),
        follow_redirects=False,
    )
    auth_store = PostgresAuthStore(pool)
    verifier_config = OidcVerificationConfig(
        issuer=settings.oidc_issuer_url,
        audience=settings.oidc_client_id,
        jwks_url=settings.oidc_jwks_url,
        roles_claim=settings.oidc_roles_claim,
        algorithms=settings.algorithms,
    )
    id_token_authenticator = OidcJwtAuthenticator(
        verifier_config,
        PyJwkSigningKeyProvider(verifier_config.jwks_url),
    )
    oidc_client = HttpOidcBrowserClient(
        OidcBrowserConfig(
            authorization_endpoint=settings.oidc_authorization_endpoint,
            token_endpoint=settings.oidc_token_endpoint,
            client_id=settings.oidc_client_id,
            client_secret=settings.oidc_client_secret.get_secret_value(),
            redirect_uri=settings.oidc_redirect_uri,
            scopes=settings.scopes,
        ),
        http_client,
    )
    auth = BrowserAuthService(
        auth_store,
        oidc_client,
        id_token_authenticator,
        FernetSecretProtector(settings.session_encryption_key.get_secret_value()),
    )
    tickets = HttpTicketClient(settings.ticket_service_url, http_client)
    automation = HttpAutomationClient(settings.automation_service_url, http_client)
    platform = HttpPlatformProbe(
        ticket_client=tickets,
        automation_client=automation,
        telemetry=PostgresDrTelemetryStore(pool),
        rpo_target_seconds=settings.rpo_target_seconds,
        rto_target_seconds=settings.rto_target_seconds,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        await pool.open(wait=True)
        try:
            yield
        finally:
            await http_client.aclose()
            await pool.close()

    return create_app(
        auth=auth,
        tickets=tickets,
        automation=automation,
        platform=platform,
        site=BffSite(
            mode=settings.site_mode,
            identity_provider=settings.identity_provider,
            name=settings.site_name,
        ),
        lifespan=lifespan,
    )


app = build_app()
