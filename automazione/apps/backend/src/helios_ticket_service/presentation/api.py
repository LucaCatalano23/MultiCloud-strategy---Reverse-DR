from __future__ import annotations

from contextlib import AbstractAsyncContextManager
from typing import Any, Callable
from uuid import UUID

from fastapi import Depends, FastAPI, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from helios_shared.auth import Principal, TokenAuthenticator
from helios_shared.http import ApiProblem, install_error_handlers, require_permissions
from helios_ticket_service.application.ports import TicketRepository
from helios_ticket_service.application.service import (
    CreateTicket,
    TicketApplication,
    TicketNotFoundError,
    UpdateTicket,
    ticket_to_dict,
)
from helios_ticket_service.domain.models import DomainValidationError, TicketPriority, TicketStatus


class CreateTicketRequest(BaseModel):
    # str_strip_whitespace scarta valori di soli spazi PRIMA del dominio: senza,
    # un titolo "   " passa la validazione Pydantic e poi esplode come 500 non
    # gestito nel layer di dominio (mascherato dal BFF come 502).
    model_config = ConfigDict(frozen=True, extra="forbid", str_strip_whitespace=True)

    title: str = Field(min_length=3, max_length=160)
    description: str = Field(min_length=1, max_length=4000)
    priority: TicketPriority
    service: str = Field(min_length=1, max_length=120)
    environment: str = Field(min_length=1, max_length=80)
    assignee: str | None = Field(default=None, min_length=1, max_length=255)


class UpdateTicketRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid", str_strip_whitespace=True)

    title: str = Field(min_length=3, max_length=160)
    description: str = Field(min_length=1, max_length=4000)
    priority: TicketPriority
    status: TicketStatus
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

    @app.exception_handler(TicketNotFoundError)
    async def ticket_not_found(_: Request, __: TicketNotFoundError):
        from fastapi.responses import JSONResponse

        return JSONResponse(
            status_code=404,
            content={"error": {"code": "ticket_not_found", "message": "Ticket not found"}},
        )

    @app.exception_handler(DomainValidationError)
    async def domain_validation(_: Request, exc: DomainValidationError):
        from fastapi.responses import JSONResponse

        return JSONResponse(
            status_code=422,
            content={"error": {"code": "validation_error", "message": str(exc)}},
        )

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

    @app.get("/api/v1/tickets/{ticket_id}")
    async def get_ticket(
        ticket_id: UUID,
        actor: Principal = Depends(read_principal),
    ) -> dict[str, Any]:
        ticket = await application.get(ticket_id=ticket_id, actor=actor)
        return {"data": ticket_to_dict(ticket)}

    @app.patch("/api/v1/tickets/{ticket_id}")
    async def update_ticket(
        ticket_id: UUID,
        request: UpdateTicketRequest,
        actor: Principal = Depends(write_principal),
    ) -> dict[str, Any]:
        ticket = await application.update(
            ticket_id=ticket_id,
            command=UpdateTicket(
                title=request.title,
                description=request.description,
                priority=request.priority,
                status=request.status,
                service=request.service,
                environment=request.environment,
                assignee=request.assignee,
            ),
            actor=actor,
        )
        return {"data": ticket_to_dict(ticket)}

    @app.delete("/api/v1/tickets/{ticket_id}", status_code=204, response_class=Response)
    async def delete_ticket(
        ticket_id: UUID,
        actor: Principal = Depends(write_principal),
    ) -> Response:
        await application.delete(ticket_id=ticket_id, actor=actor)
        return Response(status_code=204)

    return app
