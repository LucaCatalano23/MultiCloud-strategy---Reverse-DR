from __future__ import annotations

from contextlib import AbstractAsyncContextManager
from typing import Any, Callable

from fastapi import Depends, FastAPI, Response

from helios_automation_service.application.ports import (
    AutomationExecutor,
    AutomationRepository,
)
from helios_automation_service.application.service import (
    AutomationApplication,
    automation_to_dict,
)
from helios_shared.auth import Principal, TokenAuthenticator
from helios_shared.events import EventEnvelope, EventValidationError
from helios_shared.http import ApiProblem, install_error_handlers, require_permissions


Lifespan = Callable[[FastAPI], AbstractAsyncContextManager[None]]


def create_app(
    *,
    repository: AutomationRepository,
    executor: AutomationExecutor,
    authenticator: TokenAuthenticator,
    lifespan: Lifespan | None = None,
) -> FastAPI:
    app = FastAPI(title="Helios Automation Service", version="1.0.0", lifespan=lifespan)
    install_error_handlers(app)
    application = AutomationApplication(repository, executor)
    execute_principal = require_permissions(authenticator, "automation.execute")

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok", "service": "helios-automation-service"}

    @app.get("/health/ready")
    async def ready() -> dict[str, str]:
        try:
            available = await repository.ping()
        except Exception as exc:
            raise ApiProblem(503, "not_ready", "Service is not ready") from exc
        if not available:
            raise ApiProblem(503, "not_ready", "Service is not ready")
        return {"status": "ready", "service": "helios-automation-service"}

    @app.post("/internal/v1/events", status_code=201)
    async def ingest_event(
        payload: dict[str, Any],
        response: Response,
        actor: Principal = Depends(execute_principal),
    ) -> dict[str, Any]:
        try:
            event = EventEnvelope.from_dict(payload)
        except EventValidationError as exc:
            raise ApiProblem(422, "invalid_event", "Event envelope is invalid") from exc
        existing = await repository.find_by_source_event(event.event_id)
        run = await application.handle(event, actor)
        response.status_code = 200 if existing is not None else 201
        return {"data": automation_to_dict(run)}

    return app
