from datetime import UTC, datetime
from uuid import UUID

import pytest

from helios_automation_service.application.service import AutomationApplication
from helios_automation_service.domain.models import AutomationStatus
from helios_shared.events import EventEnvelope
from tests.fakes import (
    FakeAutomationExecutor,
    InMemoryAutomationRepository,
    principal,
)


NOW = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)
EVENT_ID = UUID("20000000-0000-0000-0000-000000000001")
RUN_ID = UUID("30000000-0000-0000-0000-000000000001")


def ticket_created_event() -> EventEnvelope:
    return EventEnvelope.create(
        event_id=EVENT_ID,
        event_type="helios.ticket.created.v1",
        aggregate_type="ticket",
        aggregate_id="10000000-0000-0000-0000-000000000001",
        subject="user-123",
        occurred_at=NOW,
        data={"ticket": {"id": "10000000-0000-0000-0000-000000000001"}},
    )


@pytest.mark.unit
async def test_automation_processes_event_once_and_writes_completion_outbox() -> None:
    repository = InMemoryAutomationRepository()
    executor = FakeAutomationExecutor({"classification": "incident"})
    application = AutomationApplication(
        repository,
        executor,
        clock=lambda: NOW,
        id_factory=lambda: RUN_ID,
    )

    first = await application.handle(ticket_created_event(), principal("automation.execute"))
    second = await application.handle(ticket_created_event(), principal("automation.execute"))

    assert first == second
    assert first.status is AutomationStatus.SUCCEEDED
    assert first.result["classification"] == "incident"
    assert len(executor.events) == 1
    assert repository.events[0].event_type == "helios.automation.completed.v1"


@pytest.mark.unit
async def test_automation_records_safe_failure_without_leaking_exception_details() -> None:
    repository = InMemoryAutomationRepository()
    executor = FakeAutomationExecutor(error=RuntimeError("secret upstream detail"))
    application = AutomationApplication(
        repository,
        executor,
        clock=lambda: NOW,
        id_factory=lambda: RUN_ID,
    )

    run = await application.handle(ticket_created_event(), principal("automation.execute"))

    assert run.status is AutomationStatus.FAILED
    assert run.error_code == "automation_execution_failed"
    assert "secret" not in str(run)
    assert repository.events[0].event_type == "helios.automation.failed.v1"
