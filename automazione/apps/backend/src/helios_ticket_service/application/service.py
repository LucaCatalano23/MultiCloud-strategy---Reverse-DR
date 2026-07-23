from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Callable
from uuid import UUID, uuid4

from helios_shared.auth import Principal
from helios_shared.events import EventEnvelope
from helios_ticket_service.application.ports import TicketPage, TicketRepository
from helios_ticket_service.domain.models import Ticket, TicketPriority, TicketStatus


class TicketNotFoundError(LookupError):
    """Raised when an operation targets a ticket id that does not exist."""


@dataclass(frozen=True, slots=True)
class CreateTicket:
    title: str
    description: str
    priority: TicketPriority
    service: str
    environment: str
    assignee: str | None = None


@dataclass(frozen=True, slots=True)
class UpdateTicket:
    title: str
    description: str
    priority: TicketPriority
    status: TicketStatus
    service: str
    environment: str
    assignee: str | None = None


class TicketApplication:
    def __init__(
        self,
        repository: TicketRepository,
        *,
        clock: Callable[[], datetime] | None = None,
        id_factory: Callable[[], UUID] | None = None,
    ) -> None:
        self._repository = repository
        self._clock = clock or (lambda: datetime.now(UTC))
        self._id_factory = id_factory or uuid4

    async def create(self, command: CreateTicket, actor: Principal) -> Ticket:
        actor.require("tickets.write")
        now = self._clock()
        ticket = Ticket.open(
            ticket_id=self._id_factory(),
            title=command.title,
            description=command.description,
            priority=command.priority,
            service=command.service,
            environment=command.environment,
            assignee=command.assignee,
            created_by=_creator_identity(actor),
            created_at=now,
        )
        event = EventEnvelope.create(
            event_type="helios.ticket.created.v1",
            aggregate_type="ticket",
            aggregate_id=str(ticket.id),
            subject=actor.subject,
            occurred_at=now,
            data={"ticket": ticket_to_dict(ticket)},
        )
        return await self._repository.add(ticket, (event,))

    async def get(self, *, ticket_id: UUID, actor: Principal) -> Ticket:
        actor.require("tickets.read")
        ticket = await self._repository.get(ticket_id)
        if ticket is None:
            raise TicketNotFoundError(str(ticket_id))
        return ticket

    async def update(self, *, ticket_id: UUID, command: UpdateTicket, actor: Principal) -> Ticket:
        actor.require("tickets.write")
        existing = await self._repository.get(ticket_id)
        if existing is None:
            raise TicketNotFoundError(str(ticket_id))
        now = self._clock()
        updated = existing.update(
            title=command.title,
            description=command.description,
            priority=command.priority,
            status=command.status,
            service=command.service,
            environment=command.environment,
            assignee=command.assignee,
            updated_at=now,
        )
        event = EventEnvelope.create(
            event_type="helios.ticket.updated.v1",
            aggregate_type="ticket",
            aggregate_id=str(updated.id),
            subject=actor.subject,
            occurred_at=now,
            data={"ticket": ticket_to_dict(updated)},
        )
        return await self._repository.save(updated, (event,))

    async def delete(self, *, ticket_id: UUID, actor: Principal) -> None:
        actor.require("tickets.write")
        now = self._clock()
        event = EventEnvelope.create(
            event_type="helios.ticket.deleted.v1",
            aggregate_type="ticket",
            aggregate_id=str(ticket_id),
            subject=actor.subject,
            occurred_at=now,
            data={"ticketId": str(ticket_id)},
        )
        removed = await self._repository.delete(ticket_id, (event,))
        if not removed:
            raise TicketNotFoundError(str(ticket_id))

    async def list(self, *, actor: Principal, limit: int, cursor: str | None) -> TicketPage:
        actor.require("tickets.read")
        return await self._repository.list(limit=limit, cursor=cursor)


def _creator_identity(actor: Principal) -> str:
    # Il creatore mostrato all'utente deve coincidere con chi ha davvero creato
    # il ticket: preferiamo il nome visualizzato, poi l'email, e solo come ultima
    # risorsa il subject opaco del token (che è comunque sempre presente).
    return actor.display_name or actor.email or actor.subject


def ticket_to_dict(ticket: Ticket) -> dict[str, str | None]:
    return {
        "id": str(ticket.id),
        "title": ticket.title,
        "description": ticket.description,
        "priority": ticket.priority.value,
        "status": ticket.status.value,
        "assignee": ticket.assignee,
        "service": ticket.service,
        "environment": ticket.environment,
        "createdBy": ticket.created_by,
        "createdAt": ticket.created_at.isoformat(),
        "updatedAt": ticket.updated_at.isoformat(),
    }
