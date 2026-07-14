from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    ticket = event.get("ticket") or {}
    return {
        "eventType": event.get("eventType", "ticket.process"),
        "ticketId": ticket.get("id"),
        "provider": "aws-lambda",
        "runtime": "localstack-cloud",
        "region": "eu-west-1",
        "requestId": getattr(context, "aws_request_id", None),
        "processedAt": datetime.now(timezone.utc).isoformat(),
    }

