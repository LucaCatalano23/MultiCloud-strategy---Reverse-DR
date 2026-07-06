from __future__ import annotations

import json
from typing import Any


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Minimal Lambda handler used only to prove the DR runtime contract."""
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(
            {
                "message": "Lambda executed through AWS-compatible event contract",
                "method": event.get("httpMethod"),
                "path": event.get("path"),
                "requestId": event.get("requestContext", {}).get("requestId"),
            }
        ),
    }
