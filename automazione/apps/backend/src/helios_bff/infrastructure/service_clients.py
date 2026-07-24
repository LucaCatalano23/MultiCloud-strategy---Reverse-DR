from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import Any, Callable, Mapping

import httpx

from helios_bff.application.ports import DrTelemetryStore
from helios_bff.domain.telemetry import (
    BACKUP_METRIC,
    FAILOVER_METRIC,
    DrTelemetryRecord,
    age_seconds,
    classify,
)


logger = logging.getLogger(__name__)


class UpstreamServiceError(RuntimeError):
    """Failure at a downstream HTTP boundary without response-body leakage."""


class UpstreamStatusError(UpstreamServiceError):
    """Downstream responded with an HTTP error status.

    Carries only the status code, never the upstream response body, so the BFF
    can surface a truthful status (es. 403 permesso mancante, 422 payload non
    valido) invece di mascherare tutto dietro un 502 opaco.
    """

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class HttpTicketClient:
    def __init__(self, base_url: str, client: httpx.AsyncClient) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client

    async def list_tickets(self, access_token: str) -> dict[str, Any]:
        return await self._request("GET", "/api/v1/tickets", access_token)

    async def get_ticket(self, access_token: str, ticket_id: str) -> dict[str, Any]:
        return await self._request("GET", f"/api/v1/tickets/{ticket_id}", access_token)

    async def create_ticket(
        self, access_token: str, payload: Mapping[str, Any]
    ) -> dict[str, Any]:
        return await self._request("POST", "/api/v1/tickets", access_token, json=dict(payload))

    async def update_ticket(
        self, access_token: str, ticket_id: str, payload: Mapping[str, Any]
    ) -> dict[str, Any]:
        return await self._request(
            "PATCH", f"/api/v1/tickets/{ticket_id}", access_token, json=dict(payload)
        )

    async def delete_ticket(self, access_token: str, ticket_id: str) -> None:
        try:
            response = await self._client.request(
                "DELETE",
                f"{self._base_url}/api/v1/tickets/{ticket_id}",
                headers={"Authorization": f"Bearer {access_token}"},
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise UpstreamStatusError(
                exc.response.status_code, "ticket service returned an error status"
            ) from exc
        except httpx.HTTPError as exc:
            raise UpstreamServiceError("ticket service request failed") from exc

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
        except httpx.HTTPStatusError as exc:
            raise UpstreamStatusError(
                exc.response.status_code, "ticket service returned an error status"
            ) from exc
        except (httpx.HTTPError, ValueError) as exc:
            raise UpstreamServiceError("ticket service request failed") from exc
        if not isinstance(payload, dict):
            raise UpstreamServiceError("ticket service returned an invalid payload")
        return payload


class HttpAutomationClient:
    def __init__(self, base_url: str, client: httpx.AsyncClient) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client

    async def run_ticket_automation(
        self, access_token: str, event: Mapping[str, Any]
    ) -> dict[str, Any]:
        try:
            response = await self._client.post(
                f"{self._base_url}/internal/v1/events",
                headers={"Authorization": f"Bearer {access_token}"},
                json=dict(event),
            )
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPStatusError as exc:
            raise UpstreamStatusError(
                exc.response.status_code, "automation service returned an error status"
            ) from exc
        except (httpx.HTTPError, ValueError) as exc:
            raise UpstreamServiceError("automation service request failed") from exc
        if not isinstance(payload, dict):
            raise UpstreamServiceError("automation service returned an invalid payload")
        return payload

    async def ping(self) -> bool:
        try:
            response = await self._client.get(f"{self._base_url}/health/ready")
            return response.status_code == 200
        except httpx.HTTPError:
            return False


class HttpPlatformProbe:
    """Stato piattaforma e metriche DR realmente misurate.

    Le metriche non sono configurate: `rpo` deriva dall'eta' dell'ultimo backup
    registrato dal CronJob, `rto` dalla durata dell'ultimo failover registrata
    dal playbook Ansible. Cio' che resta configurabile e' solo l'*obiettivo*
    contro cui confrontarle, che e' una scelta dichiarata, non una misura.
    """

    def __init__(
        self,
        *,
        ticket_client: HttpTicketClient,
        automation_client: HttpAutomationClient,
        telemetry: DrTelemetryStore,
        rpo_target_seconds: int,
        rto_target_seconds: int,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._tickets = ticket_client
        self._automation = automation_client
        self._telemetry = telemetry
        self._rpo_target_seconds = rpo_target_seconds
        self._rto_target_seconds = rto_target_seconds
        self._clock = clock or (lambda: datetime.now(UTC))

    async def status(self) -> dict[str, Any]:
        ticket_ready = await self._tickets.ping()
        automation_ready = await self._automation.ping()
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
                "dr": await self._dr_metrics(),
                "activities": [],
            }
        }

    async def ping(self) -> bool:
        return await self._tickets.ping() and await self._automation.ping()

    async def _dr_metrics(self) -> dict[str, Any]:
        # Un database irraggiungibile non deve far fallire /platform/status: la
        # dashboard mostra "non disponibile" sulle metriche e resta comunque
        # utilizzabile per lo stato dei servizi.
        try:
            records = await self._telemetry.read((BACKUP_METRIC, FAILOVER_METRIC))
        except Exception as exc:
            # Degradare in silenzio nasconderebbe una tabella `dr_telemetry`
            # mancante (migrazione 002 non applicata), che in UI e'
            # indistinguibile da "nessun backup ancora eseguito".
            logger.warning("DR telemetry is unreadable: %s", exc, exc_info=exc)
            records = {}

        now = self._clock()
        backup = records.get(BACKUP_METRIC)
        failover = records.get(FAILOVER_METRIC)

        backup_age = age_seconds(backup.recorded_at, now) if backup else None
        failover_duration = failover.duration_seconds if failover else None

        return {
            "backup": {
                "lastSuccessAt": backup.recorded_at.isoformat() if backup else None,
                "ageSeconds": backup_age,
                "targetSeconds": self._rpo_target_seconds,
                "status": classify(backup_age, self._rpo_target_seconds),
                "detail": _detail(backup),
            },
            "failover": {
                "lastPromotionAt": failover.recorded_at.isoformat() if failover else None,
                "durationSeconds": failover_duration,
                "targetSeconds": self._rto_target_seconds,
                "status": classify(failover_duration, self._rto_target_seconds),
                "detail": _detail(failover),
            },
        }


def _detail(record: DrTelemetryRecord | None) -> dict[str, Any]:
    return dict(record.detail) if record else {}
