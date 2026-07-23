from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any, Protocol

import jwt

from helios_shared.auth import AuthenticationError, Principal


@dataclass(frozen=True, slots=True)
class OidcVerificationConfig:
    issuer: str
    audience: str
    jwks_url: str
    roles_claim: str = "roles"
    algorithms: tuple[str, ...] = ("RS256",)
    clock_skew_seconds: int = 30

    def __post_init__(self) -> None:
        if not self.issuer or not self.audience or not self.jwks_url:
            raise ValueError("OIDC issuer, audience and JWKS URL are required")
        if not self.algorithms or any(item not in {"RS256", "ES256"} for item in self.algorithms):
            raise ValueError("only asymmetric OIDC signing algorithms are accepted")


class SigningKeyProvider(Protocol):
    async def get_signing_key(self, token: str) -> object: ...


class PyJwkSigningKeyProvider:
    def __init__(self, jwks_url: str, *, lifespan_seconds: int = 300) -> None:
        self._client = jwt.PyJWKClient(
            jwks_url,
            cache_keys=True,
            cache_jwk_set=True,
            lifespan=lifespan_seconds,
        )

    async def get_signing_key(self, token: str) -> object:
        signing_key = await asyncio.to_thread(self._client.get_signing_key_from_jwt, token)
        return signing_key.key


class OidcJwtAuthenticator:
    def __init__(self, config: OidcVerificationConfig, keys: SigningKeyProvider) -> None:
        self._config = config
        self._keys = keys

    async def authenticate(
        self, token: str, *, expected_nonce: str | None = None
    ) -> Principal:
        if not token:
            raise AuthenticationError("token is missing")
        try:
            key = await self._keys.get_signing_key(token)
            claims: dict[str, Any] = jwt.decode(
                token,
                key=key,
                algorithms=list(self._config.algorithms),
                issuer=self._config.issuer,
                audience=self._config.audience,
                leeway=self._config.clock_skew_seconds,
                options={"require": ["sub", "iss", "aud", "exp"]},
            )
            if expected_nonce is not None and claims.get("nonce") != expected_nonce:
                raise AuthenticationError("OIDC nonce mismatch")
            return Principal.from_claims(claims, roles_claim=self._config.roles_claim)
        except AuthenticationError:
            raise
        except Exception as exc:
            raise AuthenticationError("token validation failed") from exc
