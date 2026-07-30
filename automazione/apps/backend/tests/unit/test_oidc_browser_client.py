from __future__ import annotations

from datetime import UTC, datetime, timedelta

import httpx
import pytest

from helios_bff.infrastructure.oidc_client import (
    HttpOidcBrowserClient,
    OidcBrowserConfig,
    OidcClientError,
)
from helios_bff.infrastructure.oidc_client_credentials import (
    CLIENT_ASSERTION_TYPE,
    ClientAuthentication,
    ClientSecretCredential,
    OidcClientCredentialError,
)

TOKEN_ENDPOINT = "https://idp.example.com/oauth2/v2.0/token"
NOW = datetime(2026, 1, 1, 12, 0, 0, tzinfo=UTC)


class StubAssertionCredential:
    """Credenziale che restituisce un'assertion fissa, senza firmare nulla."""

    def authenticate(self, *, token_endpoint: str, now: datetime) -> ClientAuthentication:
        self.seen_endpoint = token_endpoint
        self.seen_now = now
        return ClientAuthentication(
            body={
                "client_id": "bff-client",
                "client_assertion_type": CLIENT_ASSERTION_TYPE,
                "client_assertion": "stub-assertion",
            },
            basic_auth=None,
        )


class FailingCredential:
    def authenticate(self, *, token_endpoint: str, now: datetime) -> ClientAuthentication:
        del token_endpoint, now
        raise OidcClientCredentialError("certificato illeggibile")


def _build_client(credential: object) -> tuple[HttpOidcBrowserClient, list[httpx.Request]]:
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(
            200,
            json={
                "token_type": "Bearer",
                "access_token": "access",
                "id_token": "id",
                "expires_in": 3600,
            },
        )

    client = HttpOidcBrowserClient(
        OidcBrowserConfig(
            authorization_endpoint="https://idp.example.com/authorize",
            token_endpoint=TOKEN_ENDPOINT,
            client_id="bff-client",
            credential=credential,  # type: ignore[arg-type]
            redirect_uri="https://helios.example.com/api/v1/auth/callback",
            scopes=("openid", "profile"),
        ),
        httpx.AsyncClient(transport=httpx.MockTransport(handler)),
        clock=lambda: NOW,
    )
    return client, captured


@pytest.mark.unit
async def test_exchange_code_sends_the_client_assertion_in_the_body() -> None:
    credential = StubAssertionCredential()
    client, captured = _build_client(credential)

    token_set = await client.exchange_code(code="auth-code", code_verifier="verifier")

    body = captured[0].content.decode("utf-8")
    assert "client_assertion=stub-assertion" in body
    assert "grant_type=authorization_code" in body
    assert "Authorization" not in captured[0].headers
    assert credential.seen_endpoint == TOKEN_ENDPOINT
    assert token_set.expires_at == NOW + timedelta(seconds=3600)


@pytest.mark.unit
async def test_exchange_code_still_supports_http_basic_for_client_secret() -> None:
    client, captured = _build_client(
        ClientSecretCredential(client_id="bff-client", client_secret="s3cret")
    )

    await client.exchange_code(code="auth-code", code_verifier="verifier")

    assert captured[0].headers["Authorization"].startswith("Basic ")
    assert "client_assertion" not in captured[0].content.decode("utf-8")


@pytest.mark.unit
async def test_exchange_code_hides_credential_failures_behind_the_boundary_error() -> None:
    """Un errore sulla credenziale non deve trapelare al chiamante.

    Il messaggio potrebbe contenere dettagli sul materiale crittografico, e il
    livello superiore non ha comunque nulla da decidere in base al motivo.
    """
    client, captured = _build_client(FailingCredential())

    with pytest.raises(OidcClientError):
        await client.exchange_code(code="auth-code", code_verifier="verifier")

    assert captured == [], "nessuna richiesta deve raggiungere il token endpoint"
