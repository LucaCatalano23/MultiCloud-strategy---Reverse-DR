from __future__ import annotations

from typing import Any, Mapping
from uuid import UUID

from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool

from helios_automation_service.domain.models import AutomationRun, AutomationStatus
from helios_shared.events import EventEnvelope


class PostgresAutomationRepository:
    def __init__(self, pool: AsyncConnectionPool[Any]) -> None:
        self._pool = pool

    async def find_by_source_event(self, event_id: UUID) -> AutomationRun | None:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                "SELECT * FROM automation_runs WHERE source_event_id = %s",
                (event_id,),
            )
            row = await cursor.fetchone()
        return _run_from_row(row) if row else None

    async def add(self, run: AutomationRun) -> AutomationRun:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                """
                INSERT INTO automation_runs (
                  id, source_event_id, provider, status, result, error_code,
                  created_at, updated_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (source_event_id) DO NOTHING
                RETURNING *
                """,
                _run_parameters(run),
            )
            row = await cursor.fetchone()
            if row is None:
                cursor = await connection.execute(
                    "SELECT * FROM automation_runs WHERE source_event_id = %s",
                    (run.source_event_id,),
                )
                row = await cursor.fetchone()
        if row is None:
            raise RuntimeError("automation idempotency record could not be loaded")
        return _run_from_row(row)

    async def save(
        self, run: AutomationRun, events: tuple[EventEnvelope, ...]
    ) -> AutomationRun:
        async with self._pool.connection() as connection:
            async with connection.transaction():
                result = await connection.execute(
                    """
                    UPDATE automation_runs SET
                      provider = %s, status = %s, result = %s,
                      error_code = %s, updated_at = %s
                    WHERE id = %s
                    """,
                    (
                        run.provider,
                        run.status.value,
                        Jsonb(dict(run.result)),
                        run.error_code,
                        run.updated_at,
                        run.id,
                    ),
                )
                if result.rowcount != 1:
                    raise LookupError("automation run not found")
                for event in events:
                    await connection.execute(
                        """
                        INSERT INTO automation_outbox (
                          event_id, event_type, aggregate_type, aggregate_id,
                          occurred_at, payload
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
        return run

    async def get(self, run_id: UUID) -> AutomationRun | None:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                "SELECT * FROM automation_runs WHERE id = %s",
                (run_id,),
            )
            row = await cursor.fetchone()
        return _run_from_row(row) if row else None

    async def ping(self) -> bool:
        async with self._pool.connection() as connection:
            await connection.execute("SELECT 1")
        return True


def _run_parameters(run: AutomationRun) -> tuple[Any, ...]:
    return (
        run.id,
        run.source_event_id,
        run.provider,
        run.status.value,
        Jsonb(dict(run.result)),
        run.error_code,
        run.created_at,
        run.updated_at,
    )


def _run_from_row(row: Mapping[str, Any]) -> AutomationRun:
    return AutomationRun(
        id=row["id"],
        source_event_id=row["source_event_id"],
        provider=row["provider"],
        status=AutomationStatus(row["status"]),
        result=row["result"] or {},
        error_code=row["error_code"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
