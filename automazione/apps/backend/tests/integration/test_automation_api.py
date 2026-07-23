from datetime import UTC, datetime
from uuid import UUID

from fastapi.testclient import TestClient
import pytest

from helios_automation_service.presentation.api import create_app
from helios_shared.events import EventEnvelope
from tests.fakes import (
    FakeAuthenticator,
    FakeAutomationExecutor,
    InMemoryAutomationRepository,
    principal,
)


@pytest.mark.integration
def test_automation_event_ingress_is_authenticated_and_idempotent() -> None:
    event = EventEnvelope.create(
        event_id=UUID("20000000-0000-0000-0000-000000000001"),
        event_type="helios.ticket.created.v1",
        aggregate_type="ticket",
        aggregate_id="10000000-0000-0000-0000-000000000001",
        subject="user-123",
        occurred_at=datetime(2026, 7, 22, 10, 0, tzinfo=UTC),
        data={"ticket": {"id": "10000000-0000-0000-0000-000000000001"}},
    )
    executor = FakeAutomationExecutor()
    app = create_app(
        repository=InMemoryAutomationRepository(),
        executor=executor,
        authenticator=FakeAuthenticator(principal("automation.execute")),
    )

    with TestClient(app, base_url="https://automation-service.test") as client:
        first = client.post(
            "/internal/v1/events",
            headers={"Authorization": "Bearer valid-service-token"},
            json=event.to_dict(),
        )
        second = client.post(
            "/internal/v1/events",
            headers={"Authorization": "Bearer valid-service-token"},
            json=event.to_dict(),
        )

    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["data"]["id"] == second.json()["data"]["id"]
    assert first.json()["data"]["provider"] == "test-provider"
    assert first.json()["data"]["status"] == "succeeded"
    assert len(executor.events) == 1


@pytest.mark.integration
def test_automation_health_reports_repository_readiness() -> None:
    repository = InMemoryAutomationRepository()
    app = create_app(
        repository=repository,
        executor=FakeAutomationExecutor(),
        authenticator=FakeAuthenticator(principal()),
    )

    with TestClient(app, base_url="https://automation-service.test") as client:
        assert client.get("/health/live").status_code == 200
        assert client.get("/health/ready").status_code == 200
        repository.available = False
        assert client.get("/health/ready").status_code == 503
