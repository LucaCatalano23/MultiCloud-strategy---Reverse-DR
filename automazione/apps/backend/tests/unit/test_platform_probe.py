from datetime import UTC, datetime, timedelta
from typing import Any, Mapping, Sequence

import pytest

from helios_bff.domain.telemetry import BACKUP_METRIC, FAILOVER_METRIC, DrTelemetryRecord
from helios_bff.infrastructure.service_clients import HttpPlatformProbe

NOW = datetime(2026, 7, 24, 12, 0, tzinfo=UTC)


class StubTelemetryStore:
    def __init__(
        self,
        records: Mapping[str, DrTelemetryRecord] | None = None,
        error: Exception | None = None,
    ) -> None:
        self._records = records or {}
        self._error = error

    async def read(self, metrics: Sequence[str]) -> Mapping[str, DrTelemetryRecord]:
        if self._error:
            raise self._error
        return {key: value for key, value in self._records.items() if key in metrics}


class StubReadyClient:
    def __init__(self, ready: bool = True) -> None:
        self._ready = ready

    async def ping(self) -> bool:
        return self._ready


def build_probe(telemetry: StubTelemetryStore) -> HttpPlatformProbe:
    return HttpPlatformProbe(
        ticket_client=StubReadyClient(),  # type: ignore[arg-type]
        automation_client=StubReadyClient(),  # type: ignore[arg-type]
        telemetry=telemetry,
        rpo_target_seconds=900,
        rto_target_seconds=1800,
        clock=lambda: NOW,
    )


def record(metric: str, *, minutes_ago: int, duration: int | None) -> DrTelemetryRecord:
    return DrTelemetryRecord(
        metric=metric,
        recorded_at=NOW - timedelta(minutes=minutes_ago),
        duration_seconds=duration,
        detail={"site": "onprem"},
    )


@pytest.mark.unit
async def test_status_derives_rpo_from_the_last_recorded_backup() -> None:
    # Arrange
    probe = build_probe(
        StubTelemetryStore({BACKUP_METRIC: record(BACKUP_METRIC, minutes_ago=6, duration=None)})
    )

    # Act
    payload = await probe.status()

    # Assert: l'RPO e' l'eta' misurata del backup, non un valore configurato.
    backup: dict[str, Any] = payload["data"]["dr"]["backup"]
    assert backup["ageSeconds"] == 360
    assert backup["status"] == "ok"
    assert backup["lastSuccessAt"] == (NOW - timedelta(minutes=6)).isoformat()


@pytest.mark.unit
async def test_status_reports_a_late_backup_as_warning() -> None:
    probe = build_probe(
        StubTelemetryStore({BACKUP_METRIC: record(BACKUP_METRIC, minutes_ago=20, duration=None)})
    )

    payload = await probe.status()

    assert payload["data"]["dr"]["backup"]["status"] == "warning"


@pytest.mark.unit
async def test_status_reports_rto_from_the_recorded_failover_duration() -> None:
    probe = build_probe(
        StubTelemetryStore(
            {FAILOVER_METRIC: record(FAILOVER_METRIC, minutes_ago=3000, duration=1265)}
        )
    )

    payload = await probe.status()

    # L'RTO e' la durata del playbook, quindi non invecchia come l'RPO: un
    # failover vecchio ma veloce resta "ok".
    failover = payload["data"]["dr"]["failover"]
    assert failover["durationSeconds"] == 1265
    assert failover["status"] == "ok"


@pytest.mark.unit
async def test_status_reports_unknown_when_nothing_was_ever_recorded() -> None:
    probe = build_probe(StubTelemetryStore())

    payload = await probe.status()

    dr = payload["data"]["dr"]
    assert dr["backup"] == {
        "lastSuccessAt": None,
        "ageSeconds": None,
        "targetSeconds": 900,
        "status": "unknown",
        "detail": {},
    }
    assert dr["failover"]["status"] == "unknown"
    assert dr["failover"]["durationSeconds"] is None


@pytest.mark.unit
async def test_status_stays_available_when_the_telemetry_store_fails() -> None:
    # Arrange: database irraggiungibile.
    probe = build_probe(StubTelemetryStore(error=RuntimeError("database unavailable")))

    # Act
    payload = await probe.status()

    # Assert: lo stato dei servizi resta consultabile e le metriche si
    # dichiarano assenti, invece di far fallire l'intero endpoint.
    assert payload["data"]["services"][0]["status"] == "operational"
    assert payload["data"]["dr"]["backup"]["status"] == "unknown"
