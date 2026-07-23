from dataclasses import FrozenInstanceError
from datetime import UTC, datetime, timedelta
from uuid import UUID

import pytest

from helios_ticket_service.domain.models import (
    DomainValidationError,
    Ticket,
    TicketPriority,
    TicketStatus,
)


NOW = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)
TICKET_ID = UUID("10000000-0000-0000-0000-000000000001")


@pytest.mark.unit
def test_ticket_is_immutable_and_uses_frontend_contract() -> None:
    ticket = Ticket.open(
        ticket_id=TICKET_ID,
        title="Database latency",
        description="Production queries exceed the SLO.",
        priority=TicketPriority.HIGH,
        service="billing-api",
        environment="production",
        created_by="user-123",
        created_at=NOW,
        assignee=None,
    )

    assert ticket.status is TicketStatus.OPEN
    assert ticket.priority is TicketPriority.HIGH
    assert ticket.updated_at == NOW
    with pytest.raises(FrozenInstanceError):
        ticket.title = "changed"  # type: ignore[misc]


@pytest.mark.unit
def test_ticket_transition_returns_new_value_and_preserves_original() -> None:
    ticket = Ticket.open(
        ticket_id=TICKET_ID,
        title="Database latency",
        description="Production queries exceed the SLO.",
        priority=TicketPriority.HIGH,
        service="billing-api",
        environment="production",
        created_by="user-123",
        created_at=NOW,
    )

    updated = ticket.transition(
        status=TicketStatus.IN_PROGRESS,
        updated_at=NOW + timedelta(minutes=5),
        assignee="on-call@example.test",
    )

    assert ticket.status is TicketStatus.OPEN
    assert ticket.assignee is None
    assert updated.status is TicketStatus.IN_PROGRESS
    assert updated.assignee == "on-call@example.test"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("title", "description", "service", "environment"),
    [
        ("x", "valid", "billing", "production"),
        ("valid title", "", "billing", "production"),
        ("valid title", "valid", "", "production"),
        ("valid title", "valid", "billing", ""),
    ],
)
def test_ticket_rejects_invalid_boundary_values(
    title: str, description: str, service: str, environment: str
) -> None:
    with pytest.raises(DomainValidationError):
        Ticket.open(
            ticket_id=TICKET_ID,
            title=title,
            description=description,
            priority=TicketPriority.MEDIUM,
            service=service,
            environment=environment,
            created_by="user-123",
            created_at=NOW,
        )
