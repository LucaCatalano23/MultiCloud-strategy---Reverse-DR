from __future__ import annotations

from contextlib import AbstractAsyncContextManager
from typing import Any, Callable

from fastapi import Depends, FastAPI, Query, Response
from pydantic import BaseModel, ConfigDict, Field

from helios_shared.auth import Principal, TokenAuthenticator
from helios_shared.http import ApiProblem, install_error_handlers, require_permissions
from helios_ticket_service.application.ports import TicketRepository
from helios_ticket_service.application.service import CreateTicket, TicketApplication, ticket_to_dict
from helios_ticket_service.domain.models import TicketPriority


class CreateTicketRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    title: str = Field(min_length=3, max_length=160)
    description: str = Field(min_length=1, max_length=4000)
    priority: TicketPriority
    service: str = Field(min_length=1, max_length=120)
    environment: str = Field(min_length=1, max_length=80)
    assignee: str | None = Field(default=None, min_length=1, max_length=255)


Lifespan = Callable[[FastAPI], AbstractAsyncContextManager[None]]


def create_app(
    *,
    repository: TicketRepository,
    authenticator: TokenAuthenticator,
    lifespan: Lifespan | None = None,
) -> FastAPI:
    app = FastAPI(title="Helios Ticket Service", version="1.0.0", lifespan=lifespan)
    install_error_handlers(app)
    application = TicketApplication(repository)
    read_principal = require_permissions(authenticator, "tickets.read")
    write_principal = require_permissions(authenticator, "tickets.write")

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok", "service": "helios-ticket-service"}

    @app.get("/health/ready")
    async def ready() -> dict[str, str]:
        try:
            available = await repository.ping()
        except Exception as exc:
            raise ApiProblem(503, "not_ready", "Service is not ready") from exc
        if not available:
            raise ApiProblem(503, "not_ready", "Service is not ready")
        return {"status": "ready", "service": "helios-ticket-service"}

    @app.post("/api/v1/tickets", status_code=201)
    async def create_ticket(
        request: CreateTicketRequest,
        response: Response,
        actor: Principal = Depends(write_principal),
    ) -> dict[str, Any]:
        ticket = await application.create(
            CreateTicket(
                title=request.title,
                description=request.description,
                priority=request.priority,
                service=request.service,
                environment=request.environment,
                assignee=request.assignee,
            ),
            actor,
        )
        response.headers["Location"] = f"/api/v1/tickets/{ticket.id}"
        return {"data": ticket_to_dict(ticket)}

    @app.get("/api/v1/tickets")
    async def list_tickets(
        limit: int = Query(default=100, ge=1, le=100),
        cursor: str | None = Query(default=None, max_length=512),
        actor: Principal = Depends(read_principal),
    ) -> dict[str, Any]:
        page = await application.list(actor=actor, limit=limit, cursor=cursor)
        return {
            "data": [ticket_to_dict(ticket) for ticket in page.items],
            "meta": {"nextCursor": page.next_cursor},
        }

    return app
