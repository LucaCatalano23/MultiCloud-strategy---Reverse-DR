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
