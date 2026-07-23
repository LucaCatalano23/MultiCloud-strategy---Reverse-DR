from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
from enum import StrEnum
from types import MappingProxyType
from typing import Any, Mapping
from uuid import UUID


class AutomationStatus(StrEnum):
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class AutomationRun:
    id: UUID
    source_event_id: UUID
    provider: str
    status: AutomationStatus
    result: Mapping[str, Any]
    error_code: str | None
    created_at: datetime
    updated_at: datetime

    def __post_init__(self) -> None:
        if not self.provider.strip():
            raise ValueError("automation provider is required")
        if self.created_at.tzinfo is None or self.created_at.utcoffset() is None:
            raise ValueError("automation timestamps must be timezone-aware")
        if self.updated_at.tzinfo is None or self.updated_at.utcoffset() is None:
            raise ValueError("automation timestamps must be timezone-aware")
        if self.updated_at < self.created_at:
            raise ValueError("updated_at cannot precede created_at")
        object.__setattr__(self, "result", MappingProxyType(dict(self.result)))

    @classmethod
    def start(
        cls,
        *,
        run_id: UUID,
        source_event_id: UUID,
        provider: str,
        started_at: datetime,
    ) -> AutomationRun:
        return cls(
            id=run_id,
            source_event_id=source_event_id,
            provider=provider,
            status=AutomationStatus.RUNNING,
            result={},
            error_code=None,
            created_at=started_at,
            updated_at=started_at,
        )

    def succeed(self, result: Mapping[str, Any], *, completed_at: datetime) -> AutomationRun:
        return replace(
            self,
            status=AutomationStatus.SUCCEEDED,
            result=dict(result),
            error_code=None,
            updated_at=completed_at,
        )

    def fail(self, *, error_code: str, completed_at: datetime) -> AutomationRun:
        if not error_code.strip():
            raise ValueError("automation error code is required")
        return replace(
            self,
            status=AutomationStatus.FAILED,
            result={},
            error_code=error_code,
            updated_at=completed_at,
        )
