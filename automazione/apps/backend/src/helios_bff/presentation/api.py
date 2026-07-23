from __future__ import annotations

from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from typing import Any, Callable, Literal, Protocol

from fastapi import FastAPI, Header, Query, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, ConfigDict, Field

from helios_bff.application.auth_service import (
    BrowserAuthService,
    CsrfError,
    OAuthFlowError,
    SessionError,
)
from helios_bff.application.ports import PlatformProbe, TicketClient
from helios_bff.infrastructure.service_clients import UpstreamServiceError
from helios_shared.http import ApiProblem, install_error_handlers
from helios_ticket_service.domain.models import TicketPriority


SESSION_COOKIE = "__Host-helios_session"
CSRF_COOKIE = "__Host-helios_csrf"
STATE_COOKIE = "__Host-helios_oauth_state"


class BrowserAuth(Protocol):
    async def start_login(self, return_to: str | None): ...

    async def complete_login(self, *, code: str, state: str, state_cookie: str | None): ...

    async def get_principal(self, session_cookie: str | None): ...

    async def get_access_token(self, session_cookie: str) -> str: ...

    async def logout(
        self, session_cookie: str, *, csrf_cookie: str, csrf_header: str
    ) -> None: ...

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
    auth: BrowserAuth,
    tickets: TicketClient,
    platform: PlatformProbe,
    site: BffSite,
    lifespan: Lifespan | None = None,
) -> FastAPI:
    app = FastAPI(title="Helios BFF", version="1.0.0", lifespan=lifespan)
    install_error_handlers(app)

    @app.exception_handler(OAuthFlowError)
    async def oauth_error(_: Request, __: OAuthFlowError):
        return _problem(400, "oauth_flow_failed", "Authentication could not be completed")

    @app.exception_handler(CsrfError)
    async def csrf_error(_: Request, __: CsrfError):
        return _problem(403, "csrf_validation_failed", "CSRF validation failed")

    @app.exception_handler(SessionError)
    async def session_error(_: Request, __: SessionError):
        return _problem(401, "unauthenticated", "Authentication required")

    @app.exception_handler(UpstreamServiceError)
    async def upstream_error(_: Request, __: UpstreamServiceError):
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

    @app.post("/api/v1/auth/logout", status_code=204)
    async def logout(
        request: Request,
        response: Response,
        csrf_header: str | None = Header(default=None, alias="X-CSRF-Token"),
    ) -> None:
        session_cookie = request.cookies.get(SESSION_COOKIE)
        csrf_cookie = request.cookies.get(CSRF_COOKIE)
        if not session_cookie or not csrf_cookie or not csrf_header:
            raise ApiProblem(403, "csrf_validation_failed", "CSRF validation failed")
        await auth.logout(
            session_cookie,
            csrf_cookie=csrf_cookie,
            csrf_header=csrf_header,
        )
        response.delete_cookie(SESSION_COOKIE, path="/", secure=True, httponly=True, samesite="lax")
        response.delete_cookie(CSRF_COOKIE, path="/", secure=True, httponly=False, samesite="strict")

    @app.get("/api/v1/tickets")
    async def list_tickets(request: Request) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.list_tickets(access_token)

    @app.post("/api/v1/tickets", status_code=201)
    async def create_ticket(
        request: Request, payload: CreateTicketProxyRequest
    ) -> dict[str, Any]:
        access_token = await _session_access_token(auth, request)
        return await tickets.create_ticket(access_token, payload.model_dump(mode="json"))

    @app.get("/api/v1/platform/status")
    async def platform_status() -> dict[str, Any]:
        return await platform.status()

    return app


async def _session_access_token(auth: BrowserAuth, request: Request) -> str:
    session_cookie = request.cookies.get(SESSION_COOKIE)
    if not session_cookie or await auth.get_principal(session_cookie) is None:
        raise ApiProblem(401, "unauthenticated", "Authentication required")
    return await auth.get_access_token(session_cookie)


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
