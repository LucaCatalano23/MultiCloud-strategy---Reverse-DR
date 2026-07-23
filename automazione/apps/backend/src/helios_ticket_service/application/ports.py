from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from helios_shared.events import EventEnvelope
from helios_ticket_service.domain.models import Ticket


@dataclass(frozen=True, slots=True)
class TicketPage:
    items: tuple[Ticket, ...]
    next_cursor: str | None


class TicketRepository(Protocol):
    async def add(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket: ...

    async def get(self, ticket_id: UUID) -> Ticket | None: ...

    async def list(self, *, limit: int, cursor: str | None) -> TicketPage: ...

    async def save(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket: ...

    async def delete(self, ticket_id: UUID, events: tuple[EventEnvelope, ...]) -> bool: ...

    async def ping(self) -> bool: ...
