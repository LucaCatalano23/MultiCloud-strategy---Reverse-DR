from datetime import UTC, datetime
from uuid import UUID

import pytest

from helios_shared.events import EventEnvelope, EventValidationError


@pytest.mark.unit
def test_event_envelope_is_deeply_immutable_and_serializes_contract() -> None:
    occurred_at = datetime(2026, 7, 22, 10, 0, tzinfo=UTC)
    event = EventEnvelope.create(
        event_type="helios.ticket.created.v1",
        aggregate_type="ticket",
        aggregate_id="ticket-1",
        subject="user-1",
        data={"ticket": {"priority": "high"}, "labels": ["prod"]},
        occurred_at=occurred_at,
        event_id=UUID("00000000-0000-0000-0000-000000000001"),
    )

    with pytest.raises(TypeError):
        event.data["ticket"] = {}  # type: ignore[index]
    with pytest.raises(TypeError):
        event.data["ticket"]["priority"] = "low"  # type: ignore[index]

    assert event.to_dict() == {
        "eventId": "00000000-0000-0000-0000-000000000001",
        "eventType": "helios.ticket.created.v1",
        "schemaVersion": 1,
        "aggregateType": "ticket",
        "aggregateId": "ticket-1",
        "occurredAt": "2026-07-22T10:00:00+00:00",
        "subject": "user-1",
        "data": {"ticket": {"priority": "high"}, "labels": ["prod"]},
    }


@pytest.mark.unit
@pytest.mark.parametrize("event_type", ["", "ticket.created", "Helios.ticket.created.v1"])
def test_event_contract_rejects_unversioned_or_noncanonical_types(event_type: str) -> None:
    with pytest.raises(EventValidationError):
        EventEnvelope.create(
            event_type=event_type,
            aggregate_type="ticket",
            aggregate_id="ticket-1",
            subject="user-1",
            data={},
            occurred_at=datetime.now(UTC),
        )
