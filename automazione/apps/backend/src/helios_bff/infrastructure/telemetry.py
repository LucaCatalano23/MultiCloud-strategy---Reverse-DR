from __future__ import annotations

from typing import Any, Mapping, Sequence

from psycopg_pool import AsyncConnectionPool

from helios_bff.domain.telemetry import DrTelemetryRecord


class PostgresDrTelemetryStore:
    """Lettore delle metriche DR scritte da backup CronJob e playbook Ansible.

    Sola lettura per costruzione: il BFF non ha titolo per dichiarare quando un
    backup e' riuscito o quanto e' durato un failover, puo' solo riportare cio'
    che i due orchestratori hanno registrato.
    """

    def __init__(self, pool: AsyncConnectionPool[Any]) -> None:
        self._pool = pool

    async def read(self, metrics: Sequence[str]) -> Mapping[str, DrTelemetryRecord]:
        if not metrics:
            return {}
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                """
                SELECT metric, recorded_at, duration_seconds, detail
                FROM dr_telemetry
                WHERE metric = ANY(%s)
                """,
                (list(metrics),),
            )
            rows = await cursor.fetchall()
        return {row["metric"]: _record_from_row(row) for row in rows}


def _record_from_row(row: Mapping[str, Any]) -> DrTelemetryRecord:
    duration = row["duration_seconds"]
    return DrTelemetryRecord(
        metric=row["metric"],
        recorded_at=row["recorded_at"],
        duration_seconds=int(duration) if duration is not None else None,
        detail=dict(row["detail"] or {}),
    )
