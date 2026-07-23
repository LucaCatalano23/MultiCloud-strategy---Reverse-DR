from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from helios_shared.auth import (
    AuthenticationError,
    AuthorizationError,
    Principal,
    TokenAuthenticator,
)


@dataclass(frozen=True, slots=True)
class ApiProblem(Exception):
    status_code: int
    code: str
    message: str
    details: tuple[dict[str, Any], ...] = ()


_bearer = HTTPBearer(auto_error=False)
_logger = logging.getLogger(__name__)


def require_permissions(
    authenticator: TokenAuthenticator, *permissions: str
) -> Callable[..., Awaitable[Principal]]:
    async def dependency(
        credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    ) -> Principal:
        if credentials is None:
            raise ApiProblem(401, "unauthenticated", "Authentication required")
        try:
            principal = await authenticator.authenticate(credentials.credentials)
            principal.require(*permissions)
            return principal
        except AuthenticationError as exc:
            _logger.warning("Bearer token rejected: %s", exc, exc_info=exc.__cause__ or exc)
            raise ApiProblem(401, "unauthenticated", "Authentication required") from exc
        except AuthorizationError as exc:
            _logger.warning("Permission check failed: %s", exc)
            raise ApiProblem(403, "forbidden", "Insufficient permissions") from exc

    return dependency


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiProblem)
    async def handle_problem(_: Request, exc: ApiProblem) -> JSONResponse:
        error: dict[str, Any] = {"code": exc.code, "message": exc.message}
        if exc.details:
            error["details"] = list(exc.details)
        return JSONResponse(status_code=exc.status_code, content={"error": error})

    @app.exception_handler(RequestValidationError)
    async def handle_validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        details = [
            {
                "field": ".".join(str(item) for item in error["loc"][1:]),
                "message": str(error["msg"]),
                "code": str(error["type"]),
            }
            for error in exc.errors()
        ]
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "validation_error",
                    "message": "Request validation failed",
                    "details": details,
                }
            },
        )
