from __future__ import annotations

from datetime import UTC, datetime
from typing import Callable
from uuid import UUID, uuid4

from helios_automation_service.application.ports import (
    AutomationExecutor,
    AutomationRepository,
)
from helios_automation_service.domain.models import AutomationRun
from helios_shared.auth import Principal
from helios_shared.events import EventEnvelope


class AutomationApplication:
    def __init__(
        self,
        repository: AutomationRepository,
        executor: AutomationExecutor,
        *,
        clock: Callable[[], datetime] | None = None,
        id_factory: Callable[[], UUID] | None = None,
    ) -> None:
        self._repository = repository
        self._executor = executor
        self._clock = clock or (lambda: datetime.now(UTC))
        self._id_factory = id_factory or uuid4

    async def handle(self, event: EventEnvelope, actor: Principal) -> AutomationRun:
        actor.require("automation.execute")
        existing = await self._repository.find_by_source_event(event.event_id)
        if existing is not None:
            return existing

        proposed = AutomationRun.start(
            run_id=self._id_factory(),
            source_event_id=event.event_id,
            provider=self._executor.provider,
            started_at=self._clock(),
        )
        persisted = await self._repository.add(proposed)
        if persisted.id != proposed.id:
            return persisted

        try:
            result = await self._executor.execute(event)
            run = proposed.succeed(result, completed_at=self._clock())
            event_type = "helios.automation.completed.v1"
        except Exception:
            run = proposed.fail(
                error_code="automation_execution_failed",
                completed_at=self._clock(),
            )
            event_type = "helios.automation.failed.v1"

        outbox_event = EventEnvelope.create(
            event_type=event_type,
            aggregate_type="automation-run",
            aggregate_id=str(run.id),
            subject=actor.subject,
            occurred_at=run.updated_at,
            data={"automation": automation_to_dict(run)},
        )
        return await self._repository.save(run, (outbox_event,))


def automation_to_dict(run: AutomationRun) -> dict[str, object]:
    return {
        "id": str(run.id),
        "sourceEventId": str(run.source_event_id),
        "provider": run.provider,
        "status": run.status.value,
        "result": dict(run.result),
        "errorCode": run.error_code,
        "createdAt": run.created_at.isoformat(),
        "updatedAt": run.updated_at.isoformat(),
    }
