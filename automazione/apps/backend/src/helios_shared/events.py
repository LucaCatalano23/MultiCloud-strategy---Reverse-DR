from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from types import MappingProxyType
from typing import Any, Mapping
from uuid import UUID, uuid4


_EVENT_TYPE = re.compile(r"^helios(?:\.[a-z0-9]+)+\.v([1-9][0-9]*)$")


class EventValidationError(ValueError):
    """Raised when an event violates the cross-service contract."""


JsonValue = str | int | float | bool | None | Mapping[str, "JsonValue"] | tuple["JsonValue", ...]


@dataclass(frozen=True, slots=True)
class EventEnvelope:
    event_id: UUID
    event_type: str
    schema_version: int
    aggregate_type: str
    aggregate_id: str
    occurred_at: datetime
    subject: str
    data: Mapping[str, JsonValue]

    @classmethod
    def create(
        cls,
        *,
        event_type: str,
        aggregate_type: str,
        aggregate_id: str,
        subject: str,
        data: Mapping[str, Any],
        occurred_at: datetime,
        event_id: UUID | None = None,
    ) -> EventEnvelope:
        match = _EVENT_TYPE.fullmatch(event_type)
        if match is None:
            raise EventValidationError("event type must be canonical and versioned")
        if not aggregate_type or not aggregate_id or not subject:
            raise EventValidationError("aggregate and subject are required")
        if occurred_at.tzinfo is None or occurred_at.utcoffset() is None:
            raise EventValidationError("event time must be timezone-aware")
        frozen = _freeze(data)
        if not isinstance(frozen, Mapping):
            raise EventValidationError("event data must be an object")
        return cls(
            event_id=event_id or uuid4(),
            event_type=event_type,
            schema_version=int(match.group(1)),
            aggregate_type=aggregate_type,
            aggregate_id=aggregate_id,
            occurred_at=occurred_at,
            subject=subject,
            data=frozen,
        )

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> EventEnvelope:
        try:
            event_id = UUID(str(value["eventId"]))
            occurred_at = datetime.fromisoformat(str(value["occurredAt"]).replace("Z", "+00:00"))
            data = value["data"]
            if not isinstance(data, Mapping):
                raise EventValidationError("event data must be an object")
            event = cls.create(
                event_id=event_id,
                event_type=str(value["eventType"]),
                aggregate_type=str(value["aggregateType"]),
                aggregate_id=str(value["aggregateId"]),
                subject=str(value["subject"]),
                occurred_at=occurred_at,
                data=data,
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise EventValidationError("event envelope is invalid") from exc
        if value.get("schemaVersion") != event.schema_version:
            raise EventValidationError("schema version does not match event type")
        return event

    def to_dict(self) -> dict[str, Any]:
        return {
            "eventId": str(self.event_id),
            "eventType": self.event_type,
            "schemaVersion": self.schema_version,
            "aggregateType": self.aggregate_type,
            "aggregateId": self.aggregate_id,
            "occurredAt": self.occurred_at.isoformat(),
            "subject": self.subject,
            "data": _thaw(self.data),
        }


def _freeze(value: Any) -> JsonValue:
    if isinstance(value, Mapping):
        return MappingProxyType({str(key): _freeze(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise EventValidationError("event data must contain JSON-compatible values")


def _thaw(value: JsonValue) -> Any:
    if isinstance(value, Mapping):
        return {key: _thaw(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_thaw(item) for item in value]
    return value
