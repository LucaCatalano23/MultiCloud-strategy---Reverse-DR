from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Callable
from urllib.parse import urlencode

import httpx

from helios_bff.domain.auth import TokenSet


class OidcClientError(RuntimeError):
    """Safe boundary exception for identity-provider failures."""


@dataclass(frozen=True, slots=True)
class OidcBrowserConfig:
    authorization_endpoint: str
    token_endpoint: str
    client_id: str
    client_secret: str
    redirect_uri: str
    scopes: tuple[str, ...]

    def __post_init__(self) -> None:
        required = (
            self.authorization_endpoint,
            self.token_endpoint,
            self.client_id,
            self.client_secret,
            self.redirect_uri,
        )
        if not all(required) or not self.scopes:
            raise ValueError("OIDC browser configuration is incomplete")
        if "openid" not in self.scopes:
            raise ValueError("OIDC scopes must include openid")


class HttpOidcBrowserClient:
    def __init__(
        self,
        config: OidcBrowserConfig,
        client: httpx.AsyncClient,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._config = config
        self._client = client
        self._clock = clock or (lambda: datetime.now(UTC))

    def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str:
        query = urlencode(
            {
                "response_type": "code",
                "client_id": self._config.client_id,
                "redirect_uri": self._config.redirect_uri,
                "scope": " ".join(self._config.scopes),
                "state": state,
                "nonce": nonce,
                "code_challenge": code_challenge,
                "code_challenge_method": "S256",
            }
        )
        return f"{self._config.authorization_endpoint}?{query}"

    async def exchange_code(self, *, code: str, code_verifier: str) -> TokenSet:
        try:
            response = await self._client.post(
                self._config.token_endpoint,
                data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": self._config.redirect_uri,
                    "code_verifier": code_verifier,
                },
                auth=(self._config.client_id, self._config.client_secret),
            )
            response.raise_for_status()
            payload = response.json()
            if payload.get("token_type", "").lower() != "bearer":
                raise OidcClientError("OIDC token type is unsupported")
            expires_in = int(payload["expires_in"])
            return TokenSet(
                access_token=str(payload["access_token"]),
                id_token=str(payload["id_token"]),
                expires_at=self._clock() + timedelta(seconds=expires_in),
            )
        except OidcClientError:
            raise
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            raise OidcClientError("OIDC token exchange failed") from exc
