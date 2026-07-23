from datetime import UTC, datetime
from uuid import UUID

import pytest

from helios_ticket_service.application.service import (
    CreateTicket,
    TicketApplication,
    TicketNotFoundError,
    UpdateTicket,
)
from helios_ticket_service.domain.models import TicketPriority, TicketStatus
from tests.fakes import InMemoryTicketRepository, principal


NOW = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)
LATER = datetime(2026, 7, 22, 11, 0, tzinfo=UTC)
TICKET_ID = UUID("10000000-0000-0000-0000-000000000001")
MISSING_ID = UUID("10000000-0000-0000-0000-0000000000ff")


def _create_command() -> CreateTicket:
    return CreateTicket(
        title="Database latency",
        description="Production queries exceed the SLO.",
        priority=TicketPriority.HIGH,
        service="billing-api",
        environment="production",
        assignee=None,
    )


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


@pytest.mark.unit
async def test_create_ticket_records_human_creator_identity() -> None:
    repository = InMemoryTicketRepository()
    application = TicketApplication(repository, clock=lambda: NOW, id_factory=lambda: TICKET_ID)

    ticket = await application.create(_create_command(), actor=principal("tickets.write"))

    # Il creatore coincide con l'utente reale (display name del token), non con
    # il subject opaco.
    assert ticket.created_by == "Ada Lovelace"


@pytest.mark.unit
async def test_update_ticket_changes_fields_and_emits_update_event() -> None:
    repository = InMemoryTicketRepository()
    clock = iter([NOW, LATER])
    application = TicketApplication(
        repository, clock=lambda: next(clock), id_factory=lambda: TICKET_ID
    )
    await application.create(_create_command(), actor=principal("tickets.write"))

    updated = await application.update(
        ticket_id=TICKET_ID,
        command=UpdateTicket(
            title="Database latency resolved",
            description="Mitigated by scaling the read replicas.",
            priority=TicketPriority.MEDIUM,
            status=TicketStatus.IN_PROGRESS,
            service="billing-api",
            environment="production",
            assignee="Grace Hopper",
        ),
        actor=principal("tickets.write"),
    )

    assert updated.status is TicketStatus.IN_PROGRESS
    assert updated.assignee == "Grace Hopper"
    assert updated.updated_at == LATER
    assert repository.events[-1].event_type == "helios.ticket.updated.v1"


@pytest.mark.unit
async def test_update_missing_ticket_raises_not_found() -> None:
    application = TicketApplication(InMemoryTicketRepository(), clock=lambda: NOW)

    with pytest.raises(TicketNotFoundError):
        await application.update(
            ticket_id=MISSING_ID,
            command=UpdateTicket(
                title="Nope",
                description="Missing",
                priority=TicketPriority.LOW,
                status=TicketStatus.OPEN,
                service="svc",
                environment="prod",
            ),
            actor=principal("tickets.write"),
        )


@pytest.mark.unit
async def test_delete_ticket_removes_row_and_emits_delete_event() -> None:
    repository = InMemoryTicketRepository()
    application = TicketApplication(repository, clock=lambda: NOW, id_factory=lambda: TICKET_ID)
    await application.create(_create_command(), actor=principal("tickets.write"))

    await application.delete(ticket_id=TICKET_ID, actor=principal("tickets.write"))

    assert TICKET_ID not in repository.tickets
    assert repository.events[-1].event_type == "helios.ticket.deleted.v1"


@pytest.mark.unit
async def test_delete_missing_ticket_raises_not_found() -> None:
    application = TicketApplication(InMemoryTicketRepository(), clock=lambda: NOW)

    with pytest.raises(TicketNotFoundError):
        await application.delete(ticket_id=MISSING_ID, actor=principal("tickets.write"))
