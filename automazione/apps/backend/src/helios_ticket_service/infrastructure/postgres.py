from __future__ import annotations

import base64
import json
from datetime import datetime
from typing import Any, Mapping
from uuid import UUID

from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool

from helios_shared.events import EventEnvelope
from helios_ticket_service.application.ports import TicketPage
from helios_ticket_service.domain.models import Ticket, TicketPriority, TicketStatus


class PostgresTicketRepository:
    def __init__(self, pool: AsyncConnectionPool[Any]) -> None:
        self._pool = pool

    async def add(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket:
        async with self._pool.connection() as connection:
            async with connection.transaction():
                await connection.execute(
                    """
                    INSERT INTO tickets (
                      id, title, description, priority, status, assignee, service,
                      environment, created_by, created_at, updated_at
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    _ticket_parameters(ticket),
                )
                await _insert_events(connection, events)
        return ticket

    async def get(self, ticket_id: UUID) -> Ticket | None:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                "SELECT * FROM tickets WHERE id = %s",
                (ticket_id,),
            )
            row = await cursor.fetchone()
        return _ticket_from_row(row) if row else None

    async def list(self, *, limit: int, cursor: str | None) -> TicketPage:
        boundary = _decode_cursor(cursor) if cursor else None
        where = "WHERE (created_at, id) < (%s, %s)" if boundary else ""
        params: tuple[Any, ...] = (*boundary, limit + 1) if boundary else (limit + 1,)
        async with self._pool.connection() as connection:
            result = await connection.execute(
                f"""
                SELECT * FROM tickets
                {where}
                ORDER BY created_at DESC, id DESC
                LIMIT %s
                """,  # noqa: S608 -- only a fixed internal clause is interpolated
                params,
            )
            rows = await result.fetchall()
        tickets = tuple(_ticket_from_row(row) for row in rows[:limit])
        next_cursor = _encode_cursor(tickets[-1]) if len(rows) > limit and tickets else None
        return TicketPage(items=tickets, next_cursor=next_cursor)

    async def save(self, ticket: Ticket, events: tuple[EventEnvelope, ...]) -> Ticket:
        async with self._pool.connection() as connection:
            async with connection.transaction():
                result = await connection.execute(
                    """
                    UPDATE tickets SET
                      title = %s, description = %s, priority = %s, status = %s,
                      assignee = %s, service = %s, environment = %s, updated_at = %s
                    WHERE id = %s
                    """,
                    (
                        ticket.title,
                        ticket.description,
                        ticket.priority.value,
                        ticket.status.value,
                        ticket.assignee,
                        ticket.service,
                        ticket.environment,
                        ticket.updated_at,
                        ticket.id,
                    ),
                )
                if result.rowcount != 1:
                    raise LookupError("ticket not found")
                await _insert_events(connection, events)
        return ticket

    async def delete(self, ticket_id: UUID, events: tuple[EventEnvelope, ...]) -> bool:
        async with self._pool.connection() as connection:
            async with connection.transaction():
                result = await connection.execute(
                    "DELETE FROM tickets WHERE id = %s",
                    (ticket_id,),
                )
                if result.rowcount != 1:
                    return False
                await _insert_events(connection, events)
        return True

    async def ping(self) -> bool:
        async with self._pool.connection() as connection:
            await connection.execute("SELECT 1")
        return True


async def _insert_events(connection: Any, events: tuple[EventEnvelope, ...]) -> None:
    for event in events:
        await connection.execute(
            """
            INSERT INTO ticket_outbox (
              event_id, event_type, aggregate_type, aggregate_id, occurred_at, payload
            ) VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (
                event.event_id,
                event.event_type,
                event.aggregate_type,
                event.aggregate_id,
                event.occurred_at,
                Jsonb(event.to_dict()),
            ),
        )


def _ticket_parameters(ticket: Ticket) -> tuple[Any, ...]:
    return (
        ticket.id,
        ticket.title,
        ticket.description,
        ticket.priority.value,
        ticket.status.value,
        ticket.assignee,
        ticket.service,
        ticket.environment,
        ticket.created_by,
        ticket.created_at,
        ticket.updated_at,
    )


def _ticket_from_row(row: Mapping[str, Any]) -> Ticket:
    return Ticket(
        id=row["id"],
        title=row["title"],
        description=row["description"],
        priority=TicketPriority(row["priority"]),
        status=TicketStatus(row["status"]),
        assignee=row["assignee"],
        service=row["service"],
        environment=row["environment"],
        created_by=row["created_by"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _encode_cursor(ticket: Ticket) -> str:
    value = json.dumps([ticket.created_at.isoformat(), str(ticket.id)]).encode()
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def _decode_cursor(value: str) -> tuple[datetime, UUID]:
    try:
        padded = value + "=" * (-len(value) % 4)
        timestamp, ticket_id = json.loads(base64.urlsafe_b64decode(padded).decode())
        return datetime.fromisoformat(timestamp), UUID(ticket_id)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid cursor") from exc
