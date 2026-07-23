from __future__ import annotations

from typing import Any, Mapping

import httpx


class UpstreamServiceError(RuntimeError):
    """Failure at a downstream HTTP boundary without response-body leakage."""


class HttpTicketClient:
    def __init__(self, base_url: str, client: httpx.AsyncClient) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client

    async def list_tickets(self, access_token: str) -> dict[str, Any]:
        return await self._request("GET", "/api/v1/tickets", access_token)

    async def create_ticket(
        self, access_token: str, payload: Mapping[str, Any]
    ) -> dict[str, Any]:
        return await self._request("POST", "/api/v1/tickets", access_token, json=dict(payload))

    async def ping(self) -> bool:
        try:
            response = await self._client.get(f"{self._base_url}/health/ready")
            return response.status_code == 200
        except httpx.HTTPError:
            return False

    async def _request(
        self,
        method: str,
        path: str,
        access_token: str,
        **kwargs: Any,
    ) -> dict[str, Any]:
        try:
            response = await self._client.request(
                method,
                f"{self._base_url}{path}",
                headers={"Authorization": f"Bearer {access_token}"},
                **kwargs,
            )
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, dict):
                raise UpstreamServiceError("ticket service returned an invalid payload")
            return payload
        except UpstreamServiceError:
            raise
        except (httpx.HTTPError, ValueError) as exc:
            raise UpstreamServiceError("ticket service request failed") from exc


class HttpPlatformProbe:
    def __init__(
        self,
        *,
        ticket_client: HttpTicketClient,
        automation_base_url: str,
        client: httpx.AsyncClient,
        rpo_minutes: int,
        rpo_target_minutes: int,
    ) -> None:
        self._tickets = ticket_client
        self._automation_base_url = automation_base_url.rstrip("/")
        self._client = client
        self._rpo_minutes = rpo_minutes
        self._rpo_target_minutes = rpo_target_minutes

    async def status(self) -> dict[str, Any]:
        ticket_ready = await self._tickets.ping()
        automation_ready = await self._automation_ready()
        return {
            "data": {
                "services": [
                    {
                        "id": "ticket-service",
                        "name": "Ticket Service",
                        "status": "operational" if ticket_ready else "unavailable",
                    },
                    {
                        "id": "automation-service",
                        "name": "Automation Service",
                        "status": "operational" if automation_ready else "unavailable",
                    },
                ],
                "rpoMinutes": self._rpo_minutes,
                "rpoTargetMinutes": self._rpo_target_minutes,
                "activities": [],
            }
        }

    async def ping(self) -> bool:
        return await self._tickets.ping() and await self._automation_ready()

    async def _automation_ready(self) -> bool:
        try:
            response = await self._client.get(f"{self._automation_base_url}/health/ready")
            return response.status_code == 200
        except httpx.HTTPError:
            return False
