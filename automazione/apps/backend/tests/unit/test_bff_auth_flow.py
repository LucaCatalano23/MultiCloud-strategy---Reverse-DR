from dataclasses import replace
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from tests.fakes import FakeAuthenticator, principal

from helios_bff.application.auth_service import (
    BrowserAuthService,
    CsrfError,
    OAuthFlowError,
    SessionError,
)
from helios_bff.domain.auth import BrowserSession, OAuthTransaction, TokenSet

NOW = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)


class MemoryAuthStore:
    def __init__(self) -> None:
        self.transactions: dict[str, OAuthTransaction] = {}
        self.sessions: dict[str, BrowserSession] = {}

    async def save_transaction(self, transaction: OAuthTransaction) -> None:
        self.transactions[transaction.state_hash] = transaction

    async def consume_transaction(self, state_hash: str) -> OAuthTransaction | None:
        return self.transactions.pop(state_hash, None)

    async def save_session(self, session: BrowserSession) -> None:
        self.sessions[session.session_id_hash] = session

    async def get_session(self, session_id_hash: str) -> BrowserSession | None:
        return self.sessions.get(session_id_hash)

    async def delete_session(self, session_id_hash: str) -> None:
        self.sessions.pop(session_id_hash, None)

    async def ping(self) -> bool:
        return True


class PrefixProtector:
    def encrypt(self, value: str) -> str:
        return f"protected:{value}"

    def decrypt(self, value: str) -> str:
        if not value.startswith("protected:"):
            raise ValueError("ciphertext rejected")
        return value.removeprefix("protected:")


class FakeOidcBrowserClient:
    def __init__(self) -> None:
        self.authorization_request: dict[str, str] = {}
        self.exchange_request: tuple[str, str] | None = None

    def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str:
        self.authorization_request = {
            "state": state,
            "nonce": nonce,
            "code_challenge": code_challenge,
        }
        return f"https://identity.example.test/authorize?state={state}"

    async def exchange_code(self, *, code: str, code_verifier: str) -> TokenSet:
        self.exchange_request = (code, code_verifier)
        return TokenSet(
            access_token="access-token-server-side-only",
            id_token="id-token",
            expires_at=NOW + timedelta(hours=1),
        )

    def end_session_url(self) -> str:
        return "https://identity.example.test/logout?post_logout_redirect_uri=canonical"


def random_values() -> Any:
    values = iter(["state-value", "nonce-value", "v" * 64, "session-value", "csrf-value"])
    return lambda: next(values)


@pytest.mark.unit
async def test_oauth_pkce_flow_stores_only_opaque_session_identifier_in_browser() -> None:
    store = MemoryAuthStore()
    oidc = FakeOidcBrowserClient()
    verifier = FakeAuthenticator(principal("tickets.read", "tickets.write"))
    service = BrowserAuthService(
        store,
        oidc,
        verifier,
        PrefixProtector(),
        expected_issuer="https://identity.example.test/tenant/v2.0",
        clock=lambda: NOW,
        random_token=random_values(),
    )

    login = await service.start_login("/tickets")
    completed = await service.complete_login(
        code="authorization-code",
        state="state-value",
        state_cookie=login.state_cookie,
    )

    assert login.redirect_url.startswith("https://identity.example.test/authorize")
    assert oidc.exchange_request == ("authorization-code", "v" * 64)
    assert completed.session_cookie == "session-value"
    assert "access-token" not in completed.session_cookie
    assert (
        await service.get_access_token(completed.session_cookie) == "access-token-server-side-only"
    )
    stored = next(iter(store.sessions.values()))
    assert stored.encrypted_access_token != "access-token-server-side-only"
    assert completed.return_to == "/tickets"


@pytest.mark.unit
async def test_oauth_callback_rejects_state_not_bound_to_browser() -> None:
    service = BrowserAuthService(
        MemoryAuthStore(),
        FakeOidcBrowserClient(),
        FakeAuthenticator(principal()),
        PrefixProtector(),
        expected_issuer="https://identity.example.test/tenant/v2.0",
        clock=lambda: NOW,
        random_token=random_values(),
    )
    await service.start_login("/")

    with pytest.raises(OAuthFlowError):
        await service.complete_login(
            code="authorization-code",
            state="attacker-state",
            state_cookie="different-state",
        )


@pytest.mark.unit
async def test_oauth_callback_rejects_principal_from_an_unexpected_issuer() -> None:
    store = MemoryAuthStore()
    service = BrowserAuthService(
        store,
        FakeOidcBrowserClient(),
        FakeAuthenticator(principal()),
        PrefixProtector(),
        expected_issuer="https://auth.azienda.lan/realms/helios-desk",
        clock=lambda: NOW,
        random_token=random_values(),
    )
    login = await service.start_login("/")

    with pytest.raises(OAuthFlowError):
        await service.complete_login(
            code="authorization-code",
            state="state-value",
            state_cookie=login.state_cookie,
        )

    assert store.sessions == {}


@pytest.mark.unit
async def test_logout_requires_double_submit_csrf_and_deletes_session() -> None:
    store = MemoryAuthStore()
    service = BrowserAuthService(
        store,
        FakeOidcBrowserClient(),
        FakeAuthenticator(principal()),
        PrefixProtector(),
        expected_issuer="https://identity.example.test/tenant/v2.0",
        clock=lambda: NOW,
        random_token=random_values(),
    )
    login = await service.start_login("/")
    completed = await service.complete_login(
        code="authorization-code", state="state-value", state_cookie=login.state_cookie
    )

    with pytest.raises(CsrfError):
        await service.logout(
            completed.session_cookie,
            csrf_cookie=completed.csrf_token,
            csrf_header="wrong",
        )

    logout_url = await service.logout(
        completed.session_cookie,
        csrf_cookie=completed.csrf_token,
        csrf_header=completed.csrf_token,
    )
    assert not store.sessions
    assert logout_url.startswith("https://identity.example.test/logout?")


@pytest.mark.unit
@pytest.mark.parametrize(
    ("previous_issuer", "active_issuer"),
    [
        (
            "https://identity.example.test/tenant/v2.0",
            "https://auth.azienda.lan/realms/helios-desk",
        ),
        (
            "https://auth.azienda.lan/realms/helios-desk",
            "https://identity.example.test/tenant/v2.0",
        ),
    ],
)
async def test_session_from_previous_identity_provider_is_rejected_and_deleted(
    previous_issuer: str,
    active_issuer: str,
) -> None:
    store = MemoryAuthStore()
    previous_principal = replace(principal(), issuer=previous_issuer)
    previous_site = BrowserAuthService(
        store,
        FakeOidcBrowserClient(),
        FakeAuthenticator(previous_principal),
        PrefixProtector(),
        expected_issuer=previous_issuer,
        clock=lambda: NOW,
        random_token=random_values(),
    )
    login = await previous_site.start_login("/")
    completed = await previous_site.complete_login(
        code="authorization-code",
        state="state-value",
        state_cookie=login.state_cookie,
    )
    active_site = BrowserAuthService(
        store,
        FakeOidcBrowserClient(),
        FakeAuthenticator(principal()),
        PrefixProtector(),
        expected_issuer=active_issuer,
        clock=lambda: NOW,
    )

    assert await active_site.get_principal(completed.session_cookie) is None
    assert store.sessions == {}
    with pytest.raises(SessionError):
        await active_site.get_access_token(completed.session_cookie)
