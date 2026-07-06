from __future__ import annotations

import base64
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass
from urllib.parse import parse_qsl
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response, status
from pythonjsonlogger import jsonlogger


RIE_INVOCATION_PATH = "/2015-03-31/functions/function/invocations"


def configure_logging() -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(
        jsonlogger.JsonFormatter(
            "%(asctime)s %(levelname)s %(name)s %(message)s "
            "%(request_id)s %(method)s %(path)s %(status_code)s %(duration_ms)s"
        )
    )
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


configure_logging()
logger = logging.getLogger("lambda_dr.event_adapter")


@dataclass(frozen=True)
class Settings:
    rie_base_url: str
    request_timeout_seconds: float
    stage: str
    api_id: str
    region: str

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            rie_base_url=os.getenv("RIE_BASE_URL", "http://lambda-runtime:8080").rstrip("/"),
            request_timeout_seconds=float(os.getenv("RIE_TIMEOUT_SECONDS", "8")),
            stage=os.getenv("API_GATEWAY_STAGE", "dr"),
            api_id=os.getenv("API_GATEWAY_API_ID", "onprem-dr"),
            region=os.getenv("AWS_REGION", "eu-west-1"),
        )

    @property
    def invocation_url(self) -> str:
        return f"{self.rie_base_url}{RIE_INVOCATION_PATH}"


settings = Settings.from_environment()
app = FastAPI(title="Lambda DR Event Adapter", version="1.0.0")


def _single_value_mapping(values: dict[str, list[str]]) -> dict[str, str] | None:
    if not values:
        return None
    return {key: item[-1] for key, item in values.items() if item}


def _multi_headers(request: Request) -> dict[str, list[str]]:
    headers: dict[str, list[str]] = {}
    for raw_key, raw_value in request.scope.get("headers", []):
        key = raw_key.decode("latin-1").lower()
        value = raw_value.decode("latin-1")
        headers.setdefault(key, []).append(value)
    return headers


def _multi_query(request: Request) -> dict[str, list[str]]:
    query: dict[str, list[str]] = {}
    raw_query = request.scope.get("query_string", b"").decode("latin-1")
    for key, value in parse_qsl(raw_query, keep_blank_values=True):
        query.setdefault(key, []).append(value)
    return query


def _client_ip(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for")
    if forwarded_for:
        return forwarded_for.split(",", 1)[0].strip()
    return request.client.host if request.client else "0.0.0.0"


def _domain_name(request: Request) -> str:
    return request.headers.get("host", "localhost")


def _event_path(proxy_path: str) -> str:
    return "/" + proxy_path if proxy_path else "/"


async def build_api_gateway_proxy_event(request: Request, proxy_path: str) -> dict[str, Any]:
    body = await request.body()
    content_type = request.headers.get("content-type", "")
    is_binary = bool(body) and not (
        content_type.startswith("text/")
        or content_type.startswith("application/json")
        or content_type.startswith("application/xml")
        or content_type.startswith("application/x-www-form-urlencoded")
    )
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    path = _event_path(proxy_path)
    multi_headers = _multi_headers(request)
    multi_query = _multi_query(request)
    request_time_epoch = int(time.time() * 1000)

    return {
        "resource": "/{proxy+}",
        "path": path,
        "httpMethod": request.method,
        "headers": _single_value_mapping(multi_headers),
        "multiValueHeaders": multi_headers,
        "queryStringParameters": _single_value_mapping(multi_query),
        "multiValueQueryStringParameters": multi_query or None,
        "pathParameters": {"proxy": proxy_path} if proxy_path else None,
        "stageVariables": None,
        "requestContext": {
            "resourcePath": "/{proxy+}",
            "httpMethod": request.method,
            "path": f"/{settings.stage}{path}",
            "stage": settings.stage,
            "requestId": request_id,
            "requestTimeEpoch": request_time_epoch,
            "identity": {
                "sourceIp": _client_ip(request),
                "userAgent": request.headers.get("user-agent"),
            },
            "domainName": _domain_name(request),
            "apiId": settings.api_id,
        },
        "body": base64.b64encode(body).decode("ascii") if is_binary else body.decode("utf-8"),
        "isBase64Encoded": is_binary,
    }


def _normalize_lambda_response(payload: Any) -> Response:
    if not isinstance(payload, dict):
        raise ValueError("Lambda response must be a JSON object")

    status_code = int(payload.get("statusCode", status.HTTP_200_OK))
    if status_code < 100 or status_code > 599:
        raise ValueError("Lambda response contains an invalid statusCode")

    headers = payload.get("headers") or {}
    if not isinstance(headers, dict):
        raise ValueError("Lambda response headers must be an object")

    body = payload.get("body", "")
    if body is None:
        body = ""
    if not isinstance(body, str):
        body = json.dumps(body)

    if payload.get("isBase64Encoded") is True:
        try:
            content = base64.b64decode(body, validate=True)
        except ValueError as exc:
            raise ValueError("Lambda response body is not valid base64") from exc
    else:
        content = body.encode("utf-8")

    return Response(content=content, status_code=status_code, headers=headers)


@app.get("/health", status_code=status.HTTP_204_NO_CONTENT)
async def health() -> Response:
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.api_route("/{proxy_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def invoke_lambda(request: Request, proxy_path: str) -> Response:
    started = time.perf_counter()
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    log_context = {
        "request_id": request_id,
        "method": request.method,
        "path": _event_path(proxy_path),
        "status_code": None,
        "duration_ms": None,
    }

    try:
        event = await build_api_gateway_proxy_event(request, proxy_path)
        event["requestContext"]["requestId"] = request_id
        async with httpx.AsyncClient(timeout=settings.request_timeout_seconds) as client:
            rie_response = await client.post(settings.invocation_url, json=event)
        if rie_response.status_code >= 500:
            log_context["status_code"] = rie_response.status_code
            logger.error("rie_invocation_failed", extra=log_context)
            return Response(
                content=json.dumps({"message": "Lambda runtime unavailable"}),
                status_code=status.HTTP_502_BAD_GATEWAY,
                media_type="application/json",
            )
        rie_response.raise_for_status()
        try:
            lambda_payload = rie_response.json()
        except json.JSONDecodeError as exc:
            raise ValueError("RIE returned malformed JSON") from exc
        response = _normalize_lambda_response(lambda_payload)
        log_context["status_code"] = response.status_code
        return response
    except httpx.TimeoutException:
        log_context["status_code"] = status.HTTP_504_GATEWAY_TIMEOUT
        logger.warning("rie_invocation_timeout", extra=log_context)
        return Response(
            content=json.dumps({"message": "Lambda runtime timeout"}),
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            media_type="application/json",
        )
    except (httpx.HTTPError, ValueError) as exc:
        log_context["status_code"] = status.HTTP_502_BAD_GATEWAY
        logger.error("adapter_invocation_error", extra={**log_context, "error": str(exc)})
        return Response(
            content=json.dumps({"message": "Invalid Lambda runtime response"}),
            status_code=status.HTTP_502_BAD_GATEWAY,
            media_type="application/json",
        )
    finally:
        log_context["duration_ms"] = round((time.perf_counter() - started) * 1000, 2)
        logger.info("request_completed", extra=log_context)
