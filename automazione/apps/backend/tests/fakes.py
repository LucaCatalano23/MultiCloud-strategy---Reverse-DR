from __future__ import annotations

from dataclasses import replace
from datetime import datetime
from typing import Any
from uuid import UUID

from helios_automation_service.domain.models import AutomationRun
from helios_shared.auth import Principal
from helios_shared.events import EventEnvelope
from helios_ticket_service.domain.models import Ticket
from helios_ticket_service.application.ports import TicketPage


class FakeAuthenticator:
    def __init__(self, principal: Principal | None = None) -> None:
        self.principal = principal
        self.tokens: list[str] = []

    async def authenticate(self, token: str, *, expected_nonce: str | None = None) -> Principal:
        self.tokens.append(token)
        if self.principal is None:
            from helios_shared.auth import AuthenticationError

            raise AuthenticationError("invalid token")
        return self.principal


class InMemoryTicketRepository:
    def __init__(self) -> None:
        self.tickets: dict[UUID, Ticket] = {}
        self.events: list[EventEnvelope] = []
        self.available = True

    async def add(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket:
        self.tickets[ticket.id] = ticket
        self.events.extend(events)
        return ticket

    async def get(self, ticket_id: UUID) -> Ticket | None:
        return self.tickets.get(ticket_id)

    async def list(self, *, limit: int, cursor: str | None) -> TicketPage:
        items = tuple(sorted(self.tickets.values(), key=lambda item: item.created_at, reverse=True))
        return TicketPage(items=items[:limit], next_cursor=None)

    async def save(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket:
        self.tickets[ticket.id] = ticket
        self.events.extend(events)
        return ticket

    async def ping(self) -> bool:
        return self.available


class InMemoryAutomationRepository:
    def __init__(self) -> None:
        self.runs: dict[UUID, AutomationRun] = {}
        self.by_source_event: dict[UUID, UUID] = {}
        self.events: list[EventEnvelope] = []
        self.available = True

    async def find_by_source_event(self, event_id: UUID) -> AutomationRun | None:
        run_id = self.by_source_event.get(event_id)
        return self.runs.get(run_id) if run_id else None

    async def add(self, run: AutomationRun) -> AutomationRun:
        self.runs[run.id] = run
        self.by_source_event[run.source_event_id] = run.id
        return run

    async def save(
        self, run: AutomationRun, events: tuple[EventEnvelope, ...]
    ) -> AutomationRun:
        self.runs[run.id] = run
        self.events.extend(events)
        return run

    async def get(self, run_id: UUID) -> AutomationRun | None:
        return self.runs.get(run_id)

    async def ping(self) -> bool:
        return self.available


class FakeAutomationExecutor:
    provider = "test-provider"

    def __init__(self, result: dict[str, Any] | None = None, error: Exception | None = None) -> None:
        self.result = result or {"classification": "incident"}
        self.error = error
        self.events: list[EventEnvelope] = []

    async def execute(self, event: EventEnvelope) -> dict[str, Any]:
        self.events.append(event)
        if self.error:
            raise self.error
        return dict(self.result)


def principal(*permissions: str) -> Principal:
    return Principal(
        subject="user-123",
        issuer="https://identity.example.test/tenant/v2.0",
        audience=("api://reverse-dr-helpdesk",),
        display_name="Ada Lovelace",
        email="ada@example.test",
        permissions=frozenset(permissions),
    )
