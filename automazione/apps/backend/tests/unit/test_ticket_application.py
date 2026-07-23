from datetime import UTC, datetime
from uuid import UUID

import pytest

from helios_ticket_service.application.service import CreateTicket, TicketApplication
from helios_ticket_service.domain.models import TicketPriority
from tests.fakes import InMemoryTicketRepository, principal


NOW = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)
TICKET_ID = UUID("10000000-0000-0000-0000-000000000001")


@pytest.mark.unit
async def test_create_ticket_persists_ticket_and_outbox_event_atomically() -> None:
    repository = InMemoryTicketRepository()
    application = TicketApplication(repository, clock=lambda: NOW, id_factory=lambda: TICKET_ID)

    ticket = await application.create(
        CreateTicket(
            title="Database latency",
            description="Production queries exceed the SLO.",
            priority=TicketPriority.HIGH,
            service="billing-api",
            environment="production",
            assignee=None,
        ),
        actor=principal("tickets.write"),
    )

    assert repository.tickets[ticket.id] == ticket
    assert len(repository.events) == 1
    event = repository.events[0]
    assert event.event_type == "helios.ticket.created.v1"
    assert event.aggregate_id == str(ticket.id)
    assert event.data["ticket"]["status"] == "open"


@pytest.mark.unit
async def test_list_tickets_requires_read_permission() -> None:
    application = TicketApplication(InMemoryTicketRepository(), clock=lambda: NOW)

    from helios_shared.auth import AuthorizationError

    with pytest.raises(AuthorizationError):
        await application.list(actor=principal("tickets.write"), limit=100, cursor=None)
