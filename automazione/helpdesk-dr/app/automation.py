from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from typing import Any, Protocol

import boto3
import httpx
from botocore.config import Config


class AutomationInvocationError(RuntimeError):
    pass


@dataclass(frozen=True)
class AutomationResult:
    provider: str
    runtime: str
    payload: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class AutomationGateway(Protocol):
    @property
    def provider(self) -> str: ...

    def process_ticket(self, ticket: dict[str, Any]) -> AutomationResult: ...


class AwsLambdaGateway:
    def __init__(self) -> None:
        endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
        if not endpoint_url:
            raise RuntimeError("AWS_ENDPOINT_URL is required in aws-lambda mode")
        self._function_name = os.environ.get(
            "HELPDESK_LAMBDA_FUNCTION_NAME", "helpdesk-ticket-processor"
        )
        access_key = os.environ.get("AWS_ACCESS_KEY_ID")
        secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
        if bool(access_key) != bool(secret_key):
            raise RuntimeError(
                "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be supplied together"
            )
        credentials = {}
        if access_key and secret_key:
            credentials = {
                "aws_access_key_id": access_key,
                "aws_secret_access_key": secret_key,
            }

        self._client = boto3.client(
            "lambda",
            endpoint_url=endpoint_url,
            region_name=os.environ.get("AWS_REGION", "eu-west-1"),
            config=Config(
                connect_timeout=2,
                read_timeout=10,
                retries={"max_attempts": 2, "mode": "standard"},
            ),
            **credentials,
        )

    @property
    def provider(self) -> str:
        return "aws-lambda"

    def process_ticket(self, ticket: dict[str, Any]) -> AutomationResult:
        event = {"eventType": "ticket.process", "ticket": ticket}
        try:
            response = self._client.invoke(
                FunctionName=self._function_name,
                InvocationType="RequestResponse",
                Payload=json.dumps(event).encode("utf-8"),
            )
            payload = json.loads(response["Payload"].read())
        except Exception as exc:
            raise AutomationInvocationError("AWS Lambda invocation failed") from exc

        if response.get("FunctionError"):
            raise AutomationInvocationError(
                f"AWS Lambda returned FunctionError={response['FunctionError']}"
            )
        if not isinstance(payload, dict):
            raise AutomationInvocationError("AWS Lambda returned a non-object payload")
        return AutomationResult(
            provider="aws-lambda",
            runtime=str(payload.get("runtime", "aws-lambda-cloud")),
            payload=payload,
        )


class LambdaDrGateway:
    def __init__(self) -> None:
        self._base_url = os.environ.get(
            "LAMBDA_DR_BASE_URL",
            "http://event-adapter.lambda-dr.svc.cluster.local:8080",
        ).rstrip("/")
        self._function_name = os.environ.get(
            "HELPDESK_LAMBDA_FUNCTION_NAME", "helpdesk-ticket-processor"
        )

    @property
    def provider(self) -> str:
        return "lambda-dr"

    def process_ticket(self, ticket: dict[str, Any]) -> AutomationResult:
        ticket_id = ticket["id"]
        url = f"{self._base_url}/functions/{self._function_name}/tickets/{ticket_id}/process"
        try:
            response = httpx.post(url, json=ticket, timeout=httpx.Timeout(10, connect=2))
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise AutomationInvocationError("On-prem Lambda DR invocation failed") from exc

        if not isinstance(payload, dict):
            raise AutomationInvocationError("Lambda DR returned a non-object payload")
        return AutomationResult(
            provider="lambda-dr",
            runtime=str(payload.get("runtime", "lambda-rie-onprem")),
            payload=payload,
        )


def build_automation_gateway() -> AutomationGateway:
    mode = os.environ.get("AUTOMATION_MODE", "aws-lambda")
    if mode == "aws-lambda":
        return AwsLambdaGateway()
    if mode == "lambda-dr":
        return LambdaDrGateway()
    raise RuntimeError(f"Unsupported AUTOMATION_MODE={mode}")
