"""Autenticazione del client sul token endpoint OIDC.

Perche' esiste un'astrazione invece di un solo metodo: i due siti usano lo stesso
flusso (Authorization Code + PKCE) ma provider di identita' diversi, con vincoli
diversi su come il client si autentica.

- Primario (Entra ID aziendale): la policy del tenant vieta i client secret, la
  app registration ha una credenziale a certificato e il token endpoint accetta
  solo una `client_assertion` firmata (private_key_jwt, RFC 7523).
- DR (Keycloak locale al sito): il realm emette un client secret ordinario, non
  soggetto alla policy del tenant aziendale.

Il metodo e' quindi **configurazione per sito**, non un branch nel codice
applicativo: i Deployment restano identici e cambia solo il valore di
`OIDC_CLIENT_AUTH_METHOD`.
"""

from __future__ import annotations

import uuid
from base64 import urlsafe_b64encode
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Protocol

import jwt
from cryptography.hazmat.primitives import hashes
from cryptography.x509 import load_pem_x509_certificate

# Valore fissato da RFC 7523 §2.2: identifica il tipo di assertion inviata.
CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

# Finestra volutamente breve: l'assertion viene generata a ogni scambio e non
# viene mai riusata, quindi non c'e' motivo di renderla riutilizzabile.
DEFAULT_ASSERTION_LIFETIME = timedelta(minutes=5)


class OidcClientCredentialError(RuntimeError):
    """Errore di configurazione o di firma della credenziale client."""


@dataclass(frozen=True, slots=True)
class ClientAuthentication:
    """Come autenticare una singola richiesta al token endpoint.

    `body` contiene i campi da aggiungere al form del token request;
    `basic_auth` la coppia per l'HTTP Basic, quando il metodo la prevede.
    Esattamente uno dei due meccanismi e' popolato.
    """

    body: Mapping[str, str]
    basic_auth: tuple[str, str] | None


class OidcClientCredential(Protocol):
    def authenticate(self, *, token_endpoint: str, now: datetime) -> ClientAuthentication: ...


@dataclass(frozen=True, slots=True)
class ClientSecretCredential:
    """Autenticazione con client secret via HTTP Basic (Keycloak DR)."""

    client_id: str
    client_secret: str

    def __post_init__(self) -> None:
        if not self.client_id or not self.client_secret:
            raise OidcClientCredentialError("client secret credential is incomplete")

    def authenticate(self, *, token_endpoint: str, now: datetime) -> ClientAuthentication:
        del token_endpoint, now  # non servono a questo metodo
        return ClientAuthentication(body={}, basic_auth=(self.client_id, self.client_secret))


@dataclass(frozen=True, slots=True)
class PrivateKeyJwtCredential:
    """Autenticazione con client assertion firmata dal certificato (Entra ID).

    L'header dell'assertion porta `x5t`, l'impronta SHA-1 del certificato
    codificata base64url: e' cosi' che Entra individua quale delle credenziali
    registrate sull'applicazione ha firmato. L'impronta viene derivata dal
    certificato stesso invece di essere configurata a mano, perche' un'impronta
    copiata e disallineata dalla chiave produce un `invalid_client` che non
    spiega la causa.
    """

    client_id: str
    private_key_pem: str
    certificate_pem: str
    algorithm: str = "RS256"
    lifetime: timedelta = DEFAULT_ASSERTION_LIFETIME

    def __post_init__(self) -> None:
        if not self.client_id or not self.private_key_pem or not self.certificate_pem:
            raise OidcClientCredentialError("private_key_jwt credential is incomplete")
        if self.lifetime <= timedelta(0):
            raise OidcClientCredentialError("assertion lifetime must be positive")

    def authenticate(self, *, token_endpoint: str, now: datetime) -> ClientAuthentication:
        if not token_endpoint:
            raise OidcClientCredentialError("token endpoint is required to sign a client assertion")

        claims = {
            "iss": self.client_id,
            "sub": self.client_id,
            "aud": token_endpoint,
            "jti": str(uuid.uuid4()),
            "iat": int(now.timestamp()),
            "nbf": int(now.timestamp()),
            "exp": int((now + self.lifetime).timestamp()),
        }

        try:
            assertion = jwt.encode(
                claims,
                self.private_key_pem,
                algorithm=self.algorithm,
                headers={"x5t": self._certificate_thumbprint()},
            )
        except OidcClientCredentialError:
            raise
        except Exception as exc:  # noqa: BLE001 - la libreria di firma non tipizza gli errori
            raise OidcClientCredentialError("client assertion signing failed") from exc

        return ClientAuthentication(
            body={
                "client_id": self.client_id,
                "client_assertion_type": CLIENT_ASSERTION_TYPE,
                "client_assertion": assertion,
            },
            basic_auth=None,
        )

    def _certificate_thumbprint(self) -> str:
        try:
            certificate = load_pem_x509_certificate(self.certificate_pem.encode("utf-8"))
        except ValueError as exc:
            raise OidcClientCredentialError("client certificate is not valid PEM") from exc
        fingerprint = certificate.fingerprint(hashes.SHA1())  # noqa: S303 - x5t e' definito su SHA-1
        return urlsafe_b64encode(fingerprint).decode("ascii").rstrip("=")
