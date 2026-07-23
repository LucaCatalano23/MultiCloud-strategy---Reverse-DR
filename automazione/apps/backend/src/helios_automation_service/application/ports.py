from __future__ import annotations

from typing import Any, Mapping, Protocol
from uuid import UUID

from helios_automation_service.domain.models import AutomationRun
from helios_shared.events import EventEnvelope


class AutomationRepository(Protocol):
    async def find_by_source_event(self, event_id: UUID) -> AutomationRun | None: ...

    async def add(self, run: AutomationRun) -> AutomationRun: ...

    async def save(
        self, run: AutomationRun, events: tuple[EventEnvelope, ...]
    ) -> AutomationRun: ...

    async def get(self, run_id: UUID) -> AutomationRun | None: ...

    async def ping(self) -> bool: ...


class AutomationExecutor(Protocol):
    @property
    def provider(self) -> str: ...

    async def execute(self, event: EventEnvelope) -> Mapping[str, Any]: ...
