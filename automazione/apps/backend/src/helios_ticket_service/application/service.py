from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Callable
from uuid import UUID, uuid4

from helios_shared.auth import Principal
from helios_shared.events import EventEnvelope
from helios_ticket_service.application.ports import TicketPage, TicketRepository
from helios_ticket_service.domain.models import Ticket, TicketPriority


@dataclass(frozen=True, slots=True)
class CreateTicket:
    title: str
    description: str
    priority: TicketPriority
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
            created_by=actor.subject,
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

    async def list(self, *, actor: Principal, limit: int, cursor: str | None) -> TicketPage:
        actor.require("tickets.read")
        return await self._repository.list(limit=limit, cursor=cursor)


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
        "createdAt": ticket.created_at.isoformat(),
        "updatedAt": ticket.updated_at.isoformat(),
    }
