from dataclasses import dataclass
from typing import Any

from fastapi.testclient import TestClient
import pytest

from helios_bff.application.auth_service import CompletedLogin, LoginStart
from helios_bff.infrastructure.service_clients import UpstreamServiceError, UpstreamStatusError
from helios_bff.presentation.api import BffSite, create_app
from tests.fakes import principal


class StubBrowserAuth:
    def __init__(self, authenticated: bool = False) -> None:
        self.authenticated = authenticated
        self.logout_args: tuple[str, str, str] | None = None

    async def start_login(self, return_to: str) -> LoginStart:
        return LoginStart("https://identity.example.test/authorize", "state-cookie")

    async def complete_login(self, *, code: str, state: str, state_cookie: str) -> CompletedLogin:
        return CompletedLogin(
            session_cookie="opaque-session",
            csrf_token="csrf-token",
            principal=principal("tickets.read", "tickets.write"),
            return_to="/",
        )

    async def get_principal(self, session_cookie: str | None):
        if self.authenticated and session_cookie == "opaque-session":
            return principal("tickets.read", "tickets.write")
        return None

    async def get_access_token(self, session_cookie: str) -> str:
        assert session_cookie == "opaque-session"
        return "server-side-access-token"

    async def logout(self, session_cookie: str, *, csrf_cookie: str, csrf_header: str) -> None:
        self.logout_args = (session_cookie, csrf_cookie, csrf_header)

    async def ping(self) -> bool:
        return True


class StubTicketClient:
    def __init__(self) -> None:
        self.tokens: list[str] = []
        self.deleted: list[str] = []

    async def list_tickets(self, access_token: str) -> dict[str, Any]:
        self.tokens.append(access_token)
        return {"data": [], "meta": {"nextCursor": None}}

    async def get_ticket(self, access_token: str, ticket_id: str) -> dict[str, Any]:
        self.tokens.append(access_token)
        return {"data": {"id": ticket_id, "status": "open"}}

    async def create_ticket(self, access_token: str, payload: dict[str, Any]) -> dict[str, Any]:
        self.tokens.append(access_token)
        return {"data": {"id": "ticket-1", **payload}}

    async def update_ticket(
        self, access_token: str, ticket_id: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        self.tokens.append(access_token)
        return {"data": {"id": ticket_id, **payload}}

    async def delete_ticket(self, access_token: str, ticket_id: str) -> None:
        self.tokens.append(access_token)
        self.deleted.append(ticket_id)

    async def ping(self) -> bool:
        return True


class FailingTicketClient:
    def __init__(self, error: Exception) -> None:
        self._error = error

    async def list_tickets(self, access_token: str) -> dict[str, Any]:
        raise self._error

    async def get_ticket(self, access_token: str, ticket_id: str) -> dict[str, Any]:
        raise self._error

    async def create_ticket(self, access_token: str, payload: dict[str, Any]) -> dict[str, Any]:
        raise self._error

    async def update_ticket(
        self, access_token: str, ticket_id: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        raise self._error

    async def delete_ticket(self, access_token: str, ticket_id: str) -> None:
        raise self._error

    async def ping(self) -> bool:
        return True


class StubPlatformProbe:
    async def status(self) -> dict[str, str]:
        return {"ticketService": "ready", "automationService": "ready"}

    async def ping(self) -> bool:
        return True


SITE = BffSite(mode="dr", identity_provider="keycloak", name="on-prem-rome")


@pytest.mark.integration
def test_bff_session_contract_never_exposes_tokens() -> None:
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=StubTicketClient(),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        anonymous = client.get("/api/v1/session")
        client.cookies.set("__Host-helios_session", "opaque-session")
        authenticated = client.get("/api/v1/session")

    assert anonymous.json() == {
        "authenticated": False,
        "user": None,
        "site": {"mode": "dr", "identityProvider": "keycloak", "name": "on-prem-rome"},
    }
    payload = authenticated.json()
    assert payload["authenticated"] is True
    assert payload["user"]["id"] == "user-123"
    assert payload["user"]["roles"] == ["tickets.read", "tickets.write"]
    assert "token" not in str(payload).lower()


@pytest.mark.integration
def test_bff_login_sets_secure_state_cookie_and_redirects() -> None:
    app = create_app(
        auth=StubBrowserAuth(),
        tickets=StubTicketClient(),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        response = client.get("/api/v1/auth/login?returnTo=/tickets", follow_redirects=False)

    assert response.status_code == 307
    assert response.headers["location"] == "https://identity.example.test/authorize"
    cookie = response.headers["set-cookie"]
    assert "__Host-helios_oauth_state=state-cookie" in cookie
    assert "HttpOnly" in cookie
    assert "Secure" in cookie
    assert "SameSite=lax" in cookie


@pytest.mark.integration
def test_bff_ticket_proxy_uses_server_side_token_and_fails_closed_without_session() -> None:
    ticket_client = StubTicketClient()
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=ticket_client,
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        denied = client.get("/api/v1/tickets")
        client.cookies.set("__Host-helios_session", "opaque-session")
        allowed = client.get("/api/v1/tickets")

    assert denied.status_code == 401
    assert allowed.status_code == 200
    assert ticket_client.tokens == ["server-side-access-token"]


@pytest.mark.integration
def test_bff_logout_forwards_double_submit_values_and_clears_cookies() -> None:
    auth = StubBrowserAuth(authenticated=True)
    app = create_app(
        auth=auth,
        tickets=StubTicketClient(),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        client.cookies.set("__Host-helios_csrf", "csrf-token")
        response = client.post(
            "/api/v1/auth/logout", headers={"X-CSRF-Token": "csrf-token"}
        )

    assert response.status_code == 204
    assert auth.logout_args == ("opaque-session", "csrf-token", "csrf-token")
    assert "__Host-helios_session=\"\"" in response.headers["set-cookie"]


VALID_TICKET_PAYLOAD = {
    "title": "Ordine bloccato",
    "description": "Il checkout restituisce errore",
    "priority": "medium",
    "service": "Ordini e-Commerce",
    "environment": "On-prem DR",
}


@pytest.mark.integration
def test_bff_proxies_update_and_delete_with_server_side_token() -> None:
    ticket_client = StubTicketClient()
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=ticket_client,
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        updated = client.patch(
            "/api/v1/tickets/ticket-9",
            json={**VALID_TICKET_PAYLOAD, "status": "in_progress"},
        )
        deleted = client.delete("/api/v1/tickets/ticket-9")

    assert updated.status_code == 200
    assert updated.json()["data"]["status"] == "in_progress"
    assert deleted.status_code == 204
    assert ticket_client.deleted == ["ticket-9"]
    assert ticket_client.tokens == ["server-side-access-token", "server-side-access-token"]


@pytest.mark.integration
def test_bff_delete_maps_upstream_not_found_to_404() -> None:
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=FailingTicketClient(UpstreamStatusError(404, "missing")),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        response = client.delete("/api/v1/tickets/ticket-404")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "upstream_not_found"


@pytest.mark.integration
def test_bff_surfaces_upstream_client_status_instead_of_opaque_502() -> None:
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=FailingTicketClient(UpstreamStatusError(403, "denied")),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        response = client.post("/api/v1/tickets", json=VALID_TICKET_PAYLOAD)

    assert response.status_code == 403
    body = response.json()
    assert body["error"]["code"] == "upstream_forbidden"
    # Nessun leak del body upstream: solo il messaggio safe mappato.
    assert "denied" not in str(body).lower()


@pytest.mark.integration
def test_bff_keeps_502_for_transport_failure() -> None:
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=FailingTicketClient(UpstreamServiceError("ticket service request failed")),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        response = client.post("/api/v1/tickets", json=VALID_TICKET_PAYLOAD)

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unavailable"


@pytest.mark.integration
def test_bff_maps_unlisted_upstream_status_to_502() -> None:
    app = create_app(
        auth=StubBrowserAuth(authenticated=True),
        tickets=FailingTicketClient(UpstreamStatusError(500, "boom")),
        platform=StubPlatformProbe(),
        site=SITE,
    )

    with TestClient(app, base_url="https://desk.example.test") as client:
        client.cookies.set("__Host-helios_session", "opaque-session")
        response = client.post("/api/v1/tickets", json=VALID_TICKET_PAYLOAD)

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unavailable"
