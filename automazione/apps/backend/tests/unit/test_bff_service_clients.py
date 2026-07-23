from __future__ import annotations

import httpx
import pytest

from helios_bff.infrastructure.service_clients import (
    HttpTicketClient,
    UpstreamServiceError,
    UpstreamStatusError,
)


def _client(handler: httpx.MockTransport) -> HttpTicketClient:
    return HttpTicketClient(
        "http://ticket.svc.test:8001",
        httpx.AsyncClient(transport=handler),
    )


@pytest.mark.unit
async def test_create_ticket_returns_payload_on_success() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["Authorization"] == "Bearer server-token"
        return httpx.Response(201, json={"data": {"id": "ticket-1"}})

    tickets = _client(httpx.MockTransport(handler))

    result = await tickets.create_ticket("server-token", {"title": "x"})

    assert result == {"data": {"id": "ticket-1"}}


@pytest.mark.unit
async def test_create_ticket_surfaces_upstream_status_when_forbidden() -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        # Il ticket-service risponde 403 (token valido ma senza tickets.write):
        # deve emergere come status, non collassare in un 502 opaco.
        return httpx.Response(403, json={"error": {"code": "forbidden"}})

    tickets = _client(httpx.MockTransport(handler))

    with pytest.raises(UpstreamStatusError) as excinfo:
        await tickets.create_ticket("server-token", {"title": "x"})

    assert excinfo.value.status_code == 403


@pytest.mark.unit
async def test_create_ticket_maps_transport_failure_to_generic_error() -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    tickets = _client(httpx.MockTransport(handler))

    with pytest.raises(UpstreamServiceError) as excinfo:
        await tickets.create_ticket("server-token", {"title": "x"})

    assert not isinstance(excinfo.value, UpstreamStatusError)


@pytest.mark.unit
async def test_create_ticket_rejects_non_object_payload() -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(201, json=["not", "an", "object"])

    tickets = _client(httpx.MockTransport(handler))

    with pytest.raises(UpstreamServiceError):
        await tickets.create_ticket("server-token", {"title": "x"})
