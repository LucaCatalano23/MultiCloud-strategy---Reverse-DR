from __future__ import annotations

import logging
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from datetime import UTC, datetime
from hmac import compare_digest
from typing import Any, Literal, Protocol

from fastapi import FastAPI, Header, Query, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, ConfigDict, Field

from helios_bff.application.auth_service import (
    CsrfError,
    OAuthFlowError,
    SessionError,
)
from helios_bff.application.ports import AutomationClient, PlatformProbe, TicketClient
from helios_bff.infrastructure.service_clients import UpstreamServiceError, UpstreamStatusError
from helios_shared.events import EventEnvelope
from helios_shared.http import ApiProblem, install_error_handlers
from helios_ticket_service.domain.models import TicketPriority, TicketStatus

logger = logging.getLogger(__name__)

SESSION_COOKIE = "__Host-helios_session"
CSRF_COOKIE = "__Host-helios_csrf"
STATE_COOKIE = "__Host-helios_oauth_state"

# Mappa gli errori di status del servizio a valle su una risposta veritiera per
# il browser, senza inoltrare il body upstream. Gli status non elencati (5xx,
# imprevisti) restano un 502 "upstream_unavailable": lì il difetto è davvero del
# servizio dipendente, non della richiesta dell'utente.
_UPSTREAM_STATUS_MAP: dict[int, tuple[str, str]] = {
    401: ("upstream_unauthenticated", "The dependent service rejected the session token"),
    403: ("upstream_forbidden", "The account lacks permission for this operation"),
    404: ("upstream_not_found", "The requested resource was not found"),
    409: ("upstream_conflict", "The request conflicts with the current resource state"),
    422: ("upstream_validation_failed", "The dependent service rejected the request payload"),
    429: ("upstream_rate_limited", "The dependent service is rate limiting requests"),
}


class BrowserAuth(Protocol):
    async def start_login(self, return_to: str | None): ...

    async def complete_login(self, *, code: str, state: str, state_cookie: str | None): ...

    async def get_principal(self, session_cookie: str | None): ...

    async def get_access_token(self, session_cookie: str) -> str: ...

    async def logout(self, session_cookie: str, *, csrf_cookie: str, csrf_header: str) -> str: ...

    async def ping(self) -> bool: ...


@dataclass(frozen=True, slots=True)
class BffSite:
    mode: Literal["primary", "dr"]
    identity_provider: Literal["entra-id", "keycloak"]
    name: str

    def to_dict(self) -> dict[str, str]:
        return {
            "mode": self.mode,
            "identityProvider": self.identity_provider,
            "name": self.name,
        }


class CreateTicketProxyRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid", str_strip_whitespace=True)

    title: str = Field(min_length=3, max_length=160)
    description: str = Field(min_length=1, max_length=4000)
    priority: TicketPriority
    service: str = Field(min_length=1, max_length=120)
    environment: str = Field(min_length=1, max_length=80)
    assignee: str | None = Field(default=None, min_length=1, max_length=255)


class UpdateTicketProxyRequest(BaseModel):
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
    auth: BrowserAuth,
    tickets: TicketClient,
    automation: AutomationClient,
    platform: PlatformProbe,
    site: BffSite,
    lifespan: Lifespan | None = None,
) -> FastAPI:
    app = FastAPI(title="Helios BFF", version="1.0.0", lifespan=lifespan)
    install_error_handlers(app)

    @app.exception_handler(OAuthFlowError)
    async def oauth_error(_: Request, exc: OAuthFlowError):
        logger.warning("OAuth flow failed: %s", exc, exc_info=exc.__cause__ or exc)
        return _problem(400, "oauth_flow_failed", "Authentication could not be completed")

    @app.exception_handler(CsrfError)
    async def csrf_error(_: Request, __: CsrfError):
        return _problem(403, "csrf_validation_failed", "CSRF validation failed")

    @app.exception_handler(SessionError)
    async def session_error(_: Request, __: SessionError):
        return _problem(401, "unauthenticated", "Authentication required")

    @app.exception_handler(UpstreamStatusError)
    async def upstream_status_error(_: Request, exc: UpstreamStatusError):
        logger.warning(
            "Upstream returned HTTP %s: %s",
            exc.status_code,
            exc,
            exc_info=exc.__cause__ or exc,
        )
        mapped = _UPSTREAM_STATUS_MAP.get(exc.status_code)
        if mapped is None:
            return _problem(502, "upstream_unavailable", "A dependent service is unavailable")
        code, message = mapped
        return _problem(exc.status_code, code, message)

    @app.exception_handler(UpstreamServiceError)
    async def upstream_error(_: Request, exc: UpstreamServiceError):
        logger.warning("Upstream service call failed: %s", exc, exc_info=exc.__cause__ or exc)
        return _problem(502, "upstream_unavailable", "A dependent service is unavailable")

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok", "service": "helios-bff"}

    @app.get("/health/ready")
    async def ready() -> dict[str, str]:
        try:
            available = await auth.ping() and await tickets.ping() and await platform.ping()
        except Exception as exc:
            raise ApiProblem(503, "not_ready", "Service is not ready") from exc
        if not available:
            raise ApiProblem(503, "not_ready", "Service is not ready")
        return {"status": "ready", "service": "helios-bff"}

    @app.get("/api/v1/session")
    async def session(request: Request) -> dict[str, Any]:
        principal = await auth.get_principal(request.cookies.get(SESSION_COOKIE))
        return {
            "authenticated": principal is not None,
            "user": _principal_to_user(principal) if principal else None,
            "site": site.to_dict(),
        }

    @app.get("/api/v1/auth/login")
    async def login(return_to: str = Query(default="/", alias="returnTo", max_length=2048)):
        started = await auth.start_login(return_to)
        response = RedirectResponse(started.redirect_url, status_code=307)
        response.set_cookie(
            STATE_COOKIE,
            started.state_cookie,
            max_age=600,
            path="/",
            secure=True,
            httponly=True,
            samesite="lax",
        )
        return response

    @app.get("/api/v1/auth/callback")
    async def callback(request: Request, code: str, state: str):
        completed = await auth.complete_login(
            code=code,
            state=state,
            state_cookie=request.cookies.get(STATE_COOKIE),
        )
        response = RedirectResponse(completed.return_to, status_code=303)
        response.set_cookie(
            SESSION_COOKIE,
            completed.session_cookie,
            max_age=28800,
            path="/",
            secure=True,
            httponly=True,
            samesite="lax",
        )
        response.set_cookie(
            CSRF_COOKIE,
            completed.csrf_token,
            max_age=28800,
            path="/",
            secure=True,
            httponly=False,
            samesite="strict",
        )
        response.delete_cookie(STATE_COOKIE, path="/", secure=True, httponly=True, samesite="lax")
        return response

    @app.post("/api/v1/auth/logout", response_model=None)
    async def logout(
        request: Request,
        response: Response,
        csrf_header: str | None = Header(default=None, alias="X-CSRF-Token"),
    ) -> dict[str, str]:
        session_cookie = request.cookies.get(SESSION_COOKIE)
        csrf_cookie = request.cookies.get(CSRF_COOKIE)
        if not session_cookie or not csrf_cookie or not csrf_header:
            raise ApiProblem(403, "csrf_validation_failed", "CSRF validation failed")
        redirect_url = await auth.logout(
            session_cookie,
            csrf_cookie=csrf_cookie,
            csrf_header=csrf_header,
        )
        response.delete_cookie(SESSION_COOKIE, path="/", secure=True, httponly=True, samesite="lax")
        response.delete_cookie(
            CSRF_COOKIE, path="/", secure=True, httponly=False, samesite="strict"
        )
        return {"redirectUrl": redirect_url}

    @app.get("/api/v1/tickets")
    async def list_tickets(request: Request) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.list_tickets(access_token)

    @app.post("/api/v1/tickets", status_code=201)
    async def create_ticket(request: Request, payload: CreateTicketProxyRequest) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.create_ticket(access_token, payload.model_dump(mode="json"))

    @app.get("/api/v1/tickets/{ticket_id}")
    async def get_ticket(request: Request, ticket_id: str) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.get_ticket(access_token, ticket_id)

    @app.patch("/api/v1/tickets/{ticket_id}")
    async def update_ticket(
        request: Request, ticket_id: str, payload: UpdateTicketProxyRequest
    ) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.update_ticket(access_token, ticket_id, payload.model_dump(mode="json"))

    @app.delete("/api/v1/tickets/{ticket_id}", status_code=204, response_class=Response)
    async def delete_ticket(request: Request, ticket_id: str) -> Response:
        access_token = await _session_access_token(auth, request)
        await tickets.delete_ticket(access_token, ticket_id)
        return Response(status_code=204)

    @app.post("/api/v1/tickets/{ticket_id}/automation", status_code=202)
    async def run_ticket_automation(
        request: Request,
        ticket_id: str,
        csrf_header: str | None = Header(default=None, alias="X-CSRF-Token"),
    ) -> dict[str, Any]:
        """Esegue la function di piattaforma associata a un ticket.

        Il BFF non sceglie il runtime: costruisce l'evento e lo consegna
        all'automation service, che nel sito primario lo esegue su AWS Lambda e
        nel sito DR sullo stesso handler servito da lambda-dr/RIE. La differenza
        e' una scelta di deployment (`AUTOMATION_MODE`), non un branch di codice,
        ed e' esattamente cio' che la risposta rende visibile in dashboard.
        """
        _require_csrf(request, csrf_header)
        principal, access_token = await _session_context(auth, request)
        ticket = await tickets.get_ticket(access_token, ticket_id)
        payload = ticket.get("data")
        if not isinstance(payload, dict):
            raise ApiProblem(502, "upstream_unavailable", "A dependent service is unavailable")

        event = EventEnvelope.create(
            event_type="helios.automation.requested.v1",
            aggregate_type="ticket",
            aggregate_id=ticket_id,
            subject=principal.subject,
            occurred_at=datetime.now(UTC),
            data={"ticket": payload},
        )
        return await automation.run_ticket_automation(access_token, event.to_dict())

    @app.get("/api/v1/platform/status")
    async def platform_status() -> dict[str, Any]:
        return await platform.status()

    return app


def _require_csrf(request: Request, csrf_header: str | None) -> None:
    """Double-submit esplicito su un'azione con effetto esterno.

    Le mutazioni sui ticket si affidano al solo cookie di sessione `SameSite=lax`,
    che gia' blocca una POST cross-site. Qui la verifica e' esplicita perche'
    l'operazione esce dal perimetro applicativo e fa partire un'invocazione
    Lambda: il costo di un controllo in piu' e' trascurabile rispetto a una
    invocazione indotta da terzi.
    """
    csrf_cookie = request.cookies.get(CSRF_COOKIE)
    if not csrf_cookie or not csrf_header or not compare_digest(csrf_cookie, csrf_header):
        raise ApiProblem(403, "csrf_validation_failed", "CSRF validation failed")


async def _session_access_token(auth: BrowserAuth, request: Request) -> str:
    _, access_token = await _session_context(auth, request)
    return access_token


async def _session_context(auth: BrowserAuth, request: Request) -> tuple[Any, str]:
    session_cookie = request.cookies.get(SESSION_COOKIE)
    if not session_cookie:
        raise ApiProblem(401, "unauthenticated", "Authentication required")
    principal = await auth.get_principal(session_cookie)
    if principal is None:
        raise ApiProblem(401, "unauthenticated", "Authentication required")
    return principal, await auth.get_access_token(session_cookie)


def _principal_to_user(principal: Any) -> dict[str, Any]:
    return {
        "id": principal.subject,
        "displayName": principal.display_name,
        "email": principal.email,
        "roles": sorted(principal.permissions),
    }


def _problem(status_code: int, code: str, message: str):
    from fastapi.responses import JSONResponse

    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message}},
    )
