from fastapi.testclient import TestClient
import pytest

from helios_ticket_service.presentation.api import create_app
from tests.fakes import FakeAuthenticator, InMemoryTicketRepository, principal


@pytest.mark.integration
def test_ticket_api_creates_and_lists_frontend_contract() -> None:
    repository = InMemoryTicketRepository()
    app = create_app(
        repository=repository,
        authenticator=FakeAuthenticator(principal("tickets.read", "tickets.write")),
    )

    with TestClient(app, base_url="https://ticket-service.test") as client:
        created = client.post(
            "/api/v1/tickets",
            headers={"Authorization": "Bearer valid-token"},
            json={
                "title": "Database latency",
                "description": "Production queries exceed the SLO.",
                "priority": "high",
                "service": "billing-api",
                "environment": "production",
                "assignee": None,
            },
        )
        listed = client.get(
            "/api/v1/tickets",
            headers={"Authorization": "Bearer valid-token"},
        )

    assert created.status_code == 201
    assert created.headers["location"].startswith("/api/v1/tickets/")
    payload = created.json()["data"]
    assert payload["priority"] == "high"
    assert payload["status"] == "open"
    assert payload["createdAt"].endswith("+00:00")
    assert listed.status_code == 200
    assert listed.json()["data"] == [payload]
    assert listed.json()["meta"] == {"nextCursor": None}


@pytest.mark.integration
def test_ticket_api_rejects_missing_auth_and_invalid_input_with_stable_error() -> None:
    app = create_app(
        repository=InMemoryTicketRepository(),
        authenticator=FakeAuthenticator(principal("tickets.write")),
    )

    with TestClient(app, base_url="https://ticket-service.test") as client:
        unauthenticated = client.get("/api/v1/tickets")
        invalid = client.post(
            "/api/v1/tickets",
            headers={"Authorization": "Bearer valid-token"},
            json={
                "title": "x",
                "description": "",
                "priority": "urgent",
                "service": "",
                "environment": "",
            },
        )

    assert unauthenticated.status_code == 401
    assert unauthenticated.json() == {
        "error": {"code": "unauthenticated", "message": "Authentication required"}
    }
    assert invalid.status_code == 422
    assert invalid.json()["error"]["code"] == "validation_error"
    assert "details" in invalid.json()["error"]


CREATE_BODY = {
    "title": "Database latency",
    "description": "Production queries exceed the SLO.",
    "priority": "high",
    "service": "billing-api",
    "environment": "production",
    "assignee": None,
}


@pytest.mark.integration
def test_ticket_api_full_crud_lifecycle_with_real_creator() -> None:
    app = create_app(
        repository=InMemoryTicketRepository(),
        authenticator=FakeAuthenticator(principal("tickets.read", "tickets.write")),
    )
    auth = {"Authorization": "Bearer valid-token"}

    with TestClient(app, base_url="https://ticket-service.test") as client:
        created = client.post("/api/v1/tickets", headers=auth, json=CREATE_BODY).json()["data"]
        ticket_id = created["id"]
        # Creatore coerente con l'utente autenticato (display name del token).
        assert created["createdBy"] == "Ada Lovelace"

        fetched = client.get(f"/api/v1/tickets/{ticket_id}", headers=auth)
        assert fetched.status_code == 200
        assert fetched.json()["data"]["id"] == ticket_id

        updated = client.patch(
            f"/api/v1/tickets/{ticket_id}",
            headers=auth,
            json={
                "title": "Database latency mitigated",
                "description": "Scaled the read replicas.",
                "priority": "medium",
                "status": "in_progress",
                "service": "billing-api",
                "environment": "production",
                "assignee": "Grace Hopper",
            },
        )
        assert updated.status_code == 200
        assert updated.json()["data"]["status"] == "in_progress"
        assert updated.json()["data"]["assignee"] == "Grace Hopper"

        deleted = client.delete(f"/api/v1/tickets/{ticket_id}", headers=auth)
        assert deleted.status_code == 204
        assert client.get(f"/api/v1/tickets/{ticket_id}", headers=auth).status_code == 404


@pytest.mark.integration
def test_ticket_api_update_and_delete_missing_ticket_return_404() -> None:
    app = create_app(
        repository=InMemoryTicketRepository(),
        authenticator=FakeAuthenticator(principal("tickets.read", "tickets.write")),
    )
    auth = {"Authorization": "Bearer valid-token"}
    missing = "10000000-0000-0000-0000-0000000000ff"

    with TestClient(app, base_url="https://ticket-service.test") as client:
        patched = client.patch(
            f"/api/v1/tickets/{missing}",
            headers=auth,
            json={
                "title": "Nope missing",
                "description": "Missing",
                "priority": "low",
                "status": "open",
                "service": "svc",
                "environment": "prod",
            },
        )
        removed = client.delete(f"/api/v1/tickets/{missing}", headers=auth)

    assert patched.status_code == 404
    assert patched.json()["error"]["code"] == "ticket_not_found"
    assert removed.status_code == 404


@pytest.mark.integration
def test_ticket_api_rejects_whitespace_only_title_with_422_not_500() -> None:
    app = create_app(
        repository=InMemoryTicketRepository(),
        authenticator=FakeAuthenticator(principal("tickets.write")),
    )

    with TestClient(app, base_url="https://ticket-service.test") as client:
        response = client.post(
            "/api/v1/tickets",
            headers={"Authorization": "Bearer valid-token"},
            json={
                "title": "   ",
                "description": "Real description",
                "priority": "low",
                "service": "svc",
                "environment": "prod",
            },
        )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


@pytest.mark.integration
def test_ticket_health_separates_liveness_from_database_readiness() -> None:
    repository = InMemoryTicketRepository()
    app = create_app(repository=repository, authenticator=FakeAuthenticator(principal()))

    with TestClient(app, base_url="https://ticket-service.test") as client:
        assert client.get("/health/live").json() == {
            "status": "ok",
            "service": "helios-ticket-service",
        }
        repository.available = False
        response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "not_ready"
