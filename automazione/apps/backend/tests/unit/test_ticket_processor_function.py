"""Contratto della function condivisa fra AWS Lambda e lambda-dr.

Il valore di questi test per la tesi e' che la stessa funzione, sollecitata con
le due forme di evento prodotte dai due percorsi, restituisca lo stesso
risultato applicativo: e' l'invariante che rende il failover trasparente per
l'utente.
"""

import base64
import json

import pytest
from handler import handler

TICKET = {
    "id": "0f1a4d7c-2b6e-4f31-9a0d-3c5b8e2f7a11",
    "title": "Failover DB non completato",
    "priority": "high",
    "environment": "prod",
    "service": "Ordini",
}


def envelope(ticket: dict[str, object]) -> dict[str, object]:
    """Payload dell'invoke diretta AWS: l'EventEnvelope Helios."""
    return {
        "eventId": "6a7f0f2c-4e2b-4a7c-9b3d-1f8e5c2a9d40",
        "eventType": "helios.automation.requested.v1",
        "schemaVersion": 1,
        "aggregateType": "ticket",
        "aggregateId": str(ticket["id"]),
        "occurredAt": "2026-07-24T10:00:00+00:00",
        "subject": "user-123",
        "data": {"ticket": ticket},
    }


def proxy_event(ticket: dict[str, object], *, base64_encoded: bool = False) -> dict[str, object]:
    """Payload del percorso DR: evento API Gateway costruito da event-adapter."""
    body = json.dumps(ticket)
    return {
        "path": f"/tickets/{ticket['id']}/process",
        "httpMethod": "POST",
        "requestContext": {"requestId": "req-42"},
        "body": base64.b64encode(body.encode()).decode() if base64_encoded else body,
        "isBase64Encoded": base64_encoded,
    }


@pytest.mark.unit
def test_direct_invocation_returns_the_bare_result() -> None:
    # Act
    result = handler(envelope(TICKET), None)

    # Assert: l'executor AWS usa il payload come risultato dell'automation run,
    # quindi non deve ricevere un envelope HTTP.
    assert result["ticketId"] == TICKET["id"]
    assert "statusCode" not in result


@pytest.mark.unit
def test_proxy_invocation_returns_an_api_gateway_response() -> None:
    # Act
    response = handler(proxy_event(TICKET), None)

    # Assert: event-adapter richiede statusCode/headers/body per poter
    # ricostruire una risposta HTTP.
    assert response["statusCode"] == 200
    assert response["headers"] == {"content-type": "application/json"}
    assert json.loads(response["body"])["ticketId"] == TICKET["id"]


@pytest.mark.unit
def test_both_runtimes_produce_the_same_business_result() -> None:
    # Arrange / Act
    direct = handler(envelope(TICKET), None)
    through_proxy = json.loads(handler(proxy_event(TICKET), None)["body"])

    # Assert: i campi che dipendono dall'esecuzione (istante, request id,
    # runtime dichiarato) possono differire; la decisione applicativa no.
    business_fields = (
        "ticketId",
        "classification",
        "slaTargetMinutes",
        "suggestedQueue",
        "escalate",
    )
    assert {key: direct[key] for key in business_fields} == {
        key: through_proxy[key] for key in business_fields
    }


@pytest.mark.unit
def test_base64_encoded_body_is_decoded() -> None:
    response = handler(proxy_event(TICKET, base64_encoded=True), None)

    assert json.loads(response["body"])["ticketId"] == TICKET["id"]


@pytest.mark.unit
def test_high_priority_production_ticket_is_classified_as_incident() -> None:
    result = handler(envelope(TICKET), None)

    assert result["classification"] == "incident"
    assert result["escalate"] is True
    assert result["slaTargetMinutes"] == 30
    assert result["suggestedQueue"] == "ordini-prod"


@pytest.mark.unit
def test_high_priority_outside_production_is_not_an_incident() -> None:
    ticket = {**TICKET, "environment": "collaudo"}

    result = handler(envelope(ticket), None)

    assert result["classification"] == "service-request"
    assert result["escalate"] is False
    assert result["suggestedQueue"] == "ordini-std"


@pytest.mark.unit
def test_unknown_priority_falls_back_to_the_medium_target() -> None:
    ticket = {**TICKET, "priority": "urgentissima"}

    result = handler(envelope(ticket), None)

    assert result["slaTargetMinutes"] == 240


@pytest.mark.unit
def test_provider_and_runtime_are_declared_by_the_deployment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange: e' il manifest lambda-dr a dichiarare il sito.
    monkeypatch.setenv("HELIOS_FUNCTION_PROVIDER", "lambda-dr")
    monkeypatch.setenv("HELIOS_FUNCTION_RUNTIME", "lambda-rie-onprem")

    result = handler(envelope(TICKET), None)

    assert result["provider"] == "lambda-dr"
    assert result["runtime"] == "lambda-rie-onprem"


@pytest.mark.unit
def test_managed_aws_lambda_is_detected_without_explicit_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Arrange: AWS_EXECUTION_ENV e' valorizzata solo dalla Lambda gestita.
    monkeypatch.delenv("HELIOS_FUNCTION_PROVIDER", raising=False)
    monkeypatch.delenv("HELIOS_FUNCTION_RUNTIME", raising=False)
    monkeypatch.setenv("AWS_EXECUTION_ENV", "AWS_Lambda_python3.11")

    result = handler(envelope(TICKET), None)

    assert result["provider"] == "aws-lambda"
    assert result["runtime"] == "aws-lambda-cloud"
