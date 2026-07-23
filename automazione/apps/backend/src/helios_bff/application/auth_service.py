from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Callable

from helios_bff.application.pkce import code_challenge, normalize_return_to
from helios_bff.application.ports import AuthStore, OidcBrowserClient, SecretProtector
from helios_bff.domain.auth import BrowserSession, OAuthTransaction
from helios_shared.auth import Principal, TokenAuthenticator


class OAuthFlowError(RuntimeError):
    """Generic browser OAuth failure safe to map to a public response."""


class SessionError(RuntimeError):
    """Raised for absent, expired or corrupted sessions."""


class CsrfError(RuntimeError):
    """Raised when the double-submit CSRF proof does not match."""


@dataclass(frozen=True, slots=True)
class LoginStart:
    redirect_url: str
    state_cookie: str


@dataclass(frozen=True, slots=True)
class CompletedLogin:
    session_cookie: str
    csrf_token: str
    principal: Principal
    return_to: str


class BrowserAuthService:
    def __init__(
        self,
        store: AuthStore,
        oidc: OidcBrowserClient,
        id_token_authenticator: TokenAuthenticator,
        protector: SecretProtector,
        *,
        clock: Callable[[], datetime] | None = None,
        random_token: Callable[[], str] | None = None,
        session_ttl: timedelta = timedelta(hours=8),
        transaction_ttl: timedelta = timedelta(minutes=10),
    ) -> None:
        self._store = store
        self._oidc = oidc
        self._id_token_authenticator = id_token_authenticator
        self._protector = protector
        self._clock = clock or (lambda: datetime.now(UTC))
        self._random_token = random_token or (lambda: secrets.token_urlsafe(48))
        self._session_ttl = session_ttl
        self._transaction_ttl = transaction_ttl

    async def start_login(self, return_to: str | None) -> LoginStart:
        state = self._random_token()
        nonce = self._random_token()
        verifier = self._random_token()
        if len(verifier) < 43:
            raise OAuthFlowError("secure PKCE verifier generation failed")
        transaction = OAuthTransaction(
            state_hash=_digest(state),
            nonce=nonce,
            encrypted_code_verifier=self._protector.encrypt(verifier),
            return_to=normalize_return_to(return_to),
            expires_at=self._clock() + self._transaction_ttl,
        )
        await self._store.save_transaction(transaction)
        return LoginStart(
            redirect_url=self._oidc.authorization_url(
                state=state,
                nonce=nonce,
                code_challenge=code_challenge(verifier),
            ),
            state_cookie=state,
        )

    async def complete_login(
        self, *, code: str, state: str, state_cookie: str | None
    ) -> CompletedLogin:
        if not state_cookie or not hmac.compare_digest(state, state_cookie):
            raise OAuthFlowError("OAuth state validation failed")
        transaction = await self._store.consume_transaction(_digest(state))
        now = self._clock()
        if transaction is None or transaction.expires_at <= now:
            raise OAuthFlowError("OAuth transaction is missing or expired")
        try:
            verifier = self._protector.decrypt(transaction.encrypted_code_verifier)
            tokens = await self._oidc.exchange_code(code=code, code_verifier=verifier)
            principal = await self._id_token_authenticator.authenticate(
                tokens.id_token,
                expected_nonce=transaction.nonce,
            )
        except Exception as exc:
            raise OAuthFlowError("OIDC callback could not be completed") from exc
        session_id = self._random_token()
        csrf_token = self._random_token()
        expires_at = min(tokens.expires_at, now + self._session_ttl)
        session = BrowserSession(
            session_id_hash=_digest(session_id),
            principal=principal,
            encrypted_access_token=self._protector.encrypt(tokens.access_token),
            csrf_hash=_digest(csrf_token),
            expires_at=expires_at,
        )
        await self._store.save_session(session)
        return CompletedLogin(
            session_cookie=session_id,
            csrf_token=csrf_token,
            principal=principal,
            return_to=transaction.return_to,
        )

    async def get_principal(self, session_cookie: str | None) -> Principal | None:
        if not session_cookie:
            return None
        session = await self._store.get_session(_digest(session_cookie))
        if session is None:
            return None
        if session.expires_at <= self._clock():
            await self._store.delete_session(session.session_id_hash)
            return None
        return session.principal

    async def get_access_token(self, session_cookie: str) -> str:
        session = await self._store.get_session(_digest(session_cookie))
        if session is None or session.expires_at <= self._clock():
            raise SessionError("session is missing or expired")
        try:
            return self._protector.decrypt(session.encrypted_access_token)
        except Exception as exc:
            raise SessionError("session token cannot be decrypted") from exc

    async def logout(
        self, session_cookie: str, *, csrf_cookie: str, csrf_header: str
    ) -> None:
        if not csrf_cookie or not csrf_header or not hmac.compare_digest(csrf_cookie, csrf_header):
            raise CsrfError("CSRF validation failed")
        session = await self._store.get_session(_digest(session_cookie))
        if session is None or not hmac.compare_digest(session.csrf_hash, _digest(csrf_header)):
            raise CsrfError("CSRF validation failed")
        await self._store.delete_session(session.session_id_hash)

    async def ping(self) -> bool:
        return await self._store.ping()


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()
