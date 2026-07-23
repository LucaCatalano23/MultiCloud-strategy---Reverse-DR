from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from helios_shared.auth import Principal


@dataclass(frozen=True, slots=True)
class TokenSet:
    access_token: str
    id_token: str
    expires_at: datetime

    def __post_init__(self) -> None:
        if not self.access_token or not self.id_token:
            raise ValueError("OIDC token response is incomplete")
        _require_aware(self.expires_at)


@dataclass(frozen=True, slots=True)
class OAuthTransaction:
    state_hash: str
    nonce: str
    encrypted_code_verifier: str
    return_to: str
    expires_at: datetime

    def __post_init__(self) -> None:
        if not self.state_hash or not self.nonce or not self.encrypted_code_verifier:
            raise ValueError("OAuth transaction is incomplete")
        _require_aware(self.expires_at)


@dataclass(frozen=True, slots=True)
class BrowserSession:
    session_id_hash: str
    principal: Principal
    encrypted_access_token: str
    csrf_hash: str
    expires_at: datetime

    def __post_init__(self) -> None:
        if not self.session_id_hash or not self.encrypted_access_token or not self.csrf_hash:
            raise ValueError("browser session is incomplete")
        _require_aware(self.expires_at)


def _require_aware(value: datetime) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
