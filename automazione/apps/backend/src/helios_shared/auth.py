from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping, Protocol


class AuthenticationError(RuntimeError):
    """Raised when identity evidence cannot be trusted."""


class AuthorizationError(RuntimeError):
    """Raised when a verified identity lacks a required permission."""


@dataclass(frozen=True, slots=True)
class Principal:
    subject: str
    issuer: str
    audience: tuple[str, ...]
    display_name: str | None
    email: str | None
    permissions: frozenset[str]

    @classmethod
    def from_claims(cls, claims: Mapping[str, Any], *, roles_claim: str) -> Principal:
        subject = claims.get("sub")
        issuer = claims.get("iss")
        audience = _normalize_audience(claims.get("aud"))
        expiration = claims.get("exp")
        permissions = _read_permissions(claims, roles_claim)
        if not isinstance(subject, str) or not subject.strip():
            raise AuthenticationError("token subject is missing")
        if not isinstance(issuer, str) or not issuer.strip():
            raise AuthenticationError("token issuer is missing")
        if not isinstance(expiration, (int, float)):
            raise AuthenticationError("token expiry is missing")
        return cls(
            subject=subject,
            issuer=issuer,
            audience=audience,
            display_name=_optional_string(claims.get("name")),
            email=_optional_string(
                claims.get("email") or claims.get("preferred_username") or claims.get("upn")
            ),
            permissions=permissions,
        )

    def require(self, *permissions: str) -> None:
        missing = frozenset(permissions).difference(self.permissions)
        if missing:
            raise AuthorizationError("required permission is missing")


class TokenAuthenticator(Protocol):
    async def authenticate(
        self, token: str, *, expected_nonce: str | None = None
    ) -> Principal: ...


def _normalize_audience(value: Any) -> tuple[str, ...]:
    if isinstance(value, str) and value:
        return (value,)
    if isinstance(value, list) and value and all(isinstance(item, str) and item for item in value):
        return tuple(value)
    raise AuthenticationError("token audience is missing")


def _read_permissions(claims: Mapping[str, Any], path: str) -> frozenset[str]:
    value: Any = claims
    for segment in path.split("."):
        if not isinstance(value, Mapping) or segment not in value:
            return frozenset()
        value = value[segment]
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise AuthenticationError("role claim must be a string array")
    return frozenset(value)


def _optional_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None
