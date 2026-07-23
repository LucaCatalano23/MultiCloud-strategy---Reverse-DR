from __future__ import annotations

import asyncio
import json
from typing import Any, Mapping

import httpx

from helios_shared.events import EventEnvelope


class AutomationExecutionError(RuntimeError):
    """Safe adapter failure; upstream response bodies are intentionally omitted."""


class AwsLambdaExecutor:
    provider = "aws-lambda"

    def __init__(self, client: Any, function_name: str) -> None:
        self._client = client
        self._function_name = function_name

    async def execute(self, event: EventEnvelope) -> Mapping[str, Any]:
        return await asyncio.to_thread(self._invoke, event)

    def _invoke(self, event: EventEnvelope) -> Mapping[str, Any]:
        try:
            response = self._client.invoke(
                FunctionName=self._function_name,
                InvocationType="RequestResponse",
                Payload=json.dumps(event.to_dict()).encode("utf-8"),
            )
            payload = json.loads(response["Payload"].read())
        except Exception as exc:
            raise AutomationExecutionError("AWS Lambda invocation failed") from exc
        if response.get("FunctionError") or not isinstance(payload, dict):
            raise AutomationExecutionError("AWS Lambda returned an invalid result")
        return payload


class LambdaDrHttpExecutor:
    provider = "lambda-dr"

    def __init__(self, client: httpx.AsyncClient, base_url: str, function_name: str) -> None:
        self._client = client
        self._base_url = base_url.rstrip("/")
        self._function_name = function_name

    async def execute(self, event: EventEnvelope) -> Mapping[str, Any]:
        ticket = event.to_dict().get("data", {}).get("ticket", {})
        ticket_id = ticket.get("id") if isinstance(ticket, dict) else None
        if not isinstance(ticket_id, str) or not ticket_id:
            raise AutomationExecutionError("ticket event is missing its identifier")
        url = f"{self._base_url}/functions/{self._function_name}/tickets/{ticket_id}/process"
        try:
            response = await self._client.post(url, json=ticket)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise AutomationExecutionError("Lambda DR invocation failed") from exc
        if not isinstance(payload, dict):
            raise AutomationExecutionError("Lambda DR returned an invalid result")
        return payload
