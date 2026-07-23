from contextlib import asynccontextmanager

import boto3
import httpx
from fastapi import FastAPI
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from helios_automation_service.config import AutomationSettings
from helios_automation_service.infrastructure.executors import (
    AwsLambdaExecutor,
    LambdaDrHttpExecutor,
)
from helios_automation_service.infrastructure.postgres import PostgresAutomationRepository
from helios_automation_service.presentation.api import create_app
from helios_shared.oidc import (
    OidcJwtAuthenticator,
    OidcVerificationConfig,
    PyJwkSigningKeyProvider,
)


def build_app() -> FastAPI:
    settings = AutomationSettings()  # type: ignore[call-arg]
    pool = AsyncConnectionPool(
        conninfo=settings.database_url,
        min_size=settings.database_pool_min_size,
        max_size=settings.database_pool_max_size,
        open=False,
        kwargs={"row_factory": dict_row},
    )
    repository = PostgresAutomationRepository(pool)
    http_client: httpx.AsyncClient | None = None
    if settings.automation_mode == "aws-lambda":
        executor = AwsLambdaExecutor(
            boto3.client("lambda", region_name=settings.aws_region),
            settings.helpdesk_lambda_function_name,
        )
    else:
        if not settings.lambda_dr_base_url:
            raise ValueError("LAMBDA_DR_BASE_URL is required in lambda-dr mode")
        http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(10.0, connect=2.0),
            follow_redirects=False,
        )
        executor = LambdaDrHttpExecutor(
            http_client,
            settings.lambda_dr_base_url,
            settings.helpdesk_lambda_function_name,
        )
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
            if http_client is not None:
                await http_client.aclose()
            await pool.close()

    return create_app(
        repository=repository,
        executor=executor,
        authenticator=authenticator,
        lifespan=lifespan,
    )


app = build_app()
