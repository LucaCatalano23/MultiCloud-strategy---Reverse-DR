from contextlib import asynccontextmanager

from fastapi import FastAPI
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from helios_shared.oidc import (
    OidcJwtAuthenticator,
    OidcVerificationConfig,
    PyJwkSigningKeyProvider,
)
from helios_ticket_service.config import TicketSettings
from helios_ticket_service.infrastructure.postgres import PostgresTicketRepository
from helios_ticket_service.presentation.api import create_app


def build_app() -> FastAPI:
    settings = TicketSettings()  # type: ignore[call-arg]
    pool = AsyncConnectionPool(
        conninfo=settings.database_url,
        min_size=settings.database_pool_min_size,
        max_size=settings.database_pool_max_size,
        open=False,
        kwargs={"row_factory": dict_row},
    )
    repository = PostgresTicketRepository(pool)
    auth_config = OidcVerificationConfig(
        issuer=settings.oidc_issuer_url,
        audience=settings.oidc_audience,
        jwks_url=settings.oidc_jwks_url,
        roles_claim=settings.oidc_roles_claim,
        algorithms=settings.algorithms,
    )
    authenticator = OidcJwtAuthenticator(
        auth_config,
        PyJwkSigningKeyProvider(auth_config.jwks_url),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        await pool.open(wait=True)
        try:
            yield
        finally:
            await pool.close()

    return create_app(repository=repository, authenticator=authenticator, lifespan=lifespan)


app = build_app()
