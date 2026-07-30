from __future__ import annotations

from base64 import urlsafe_b64encode
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509 import load_pem_x509_certificate
from cryptography.x509.oid import NameOID

from helios_bff.infrastructure.oidc_client_credentials import (
    CLIENT_ASSERTION_TYPE,
    ClientSecretCredential,
    OidcClientCredentialError,
    PrivateKeyJwtCredential,
)

TOKEN_ENDPOINT = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token"
CLIENT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
NOW = datetime(2026, 7, 30, 12, 0, 0, tzinfo=UTC)


@pytest.fixture(scope="module")
def certificate_pair() -> tuple[str, str, bytes]:
    """Certificato self-signed effimero: nessun materiale reale nei test."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "helios-bff-test")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=1))
        .not_valid_after(NOW + timedelta(days=365))
        .sign(key, hashes.SHA256())
    )
    private_key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")
    certificate_pem = certificate.public_bytes(serialization.Encoding.PEM).decode("utf-8")
    # SHA-1 non e' una scelta: `x5t` e' definito su SHA-1 dalla specifica JWS.
    fingerprint = certificate.fingerprint(hashes.SHA1())  # noqa: S303
    return private_key_pem, certificate_pem, fingerprint


@pytest.mark.unit
def test_client_secret_credential_uses_http_basic_and_no_body_fields() -> None:
    credential = ClientSecretCredential(client_id=CLIENT_ID, client_secret="s3cret")

    authentication = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW)

    assert authentication.basic_auth == (CLIENT_ID, "s3cret")
    assert authentication.body == {}


@pytest.mark.unit
def test_client_secret_credential_rejects_empty_values() -> None:
    with pytest.raises(OidcClientCredentialError):
        ClientSecretCredential(client_id=CLIENT_ID, client_secret="")


@pytest.mark.unit
def test_private_key_jwt_sends_assertion_instead_of_basic_auth(
    certificate_pair: tuple[str, str, bytes],
) -> None:
    private_key_pem, certificate_pem, _ = certificate_pair
    credential = PrivateKeyJwtCredential(
        client_id=CLIENT_ID,
        private_key_pem=private_key_pem,
        certificate_pem=certificate_pem,
    )

    authentication = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW)

    assert authentication.basic_auth is None
    assert authentication.body["client_id"] == CLIENT_ID
    assert authentication.body["client_assertion_type"] == CLIENT_ASSERTION_TYPE
    assert authentication.body["client_assertion"]


@pytest.mark.unit
def test_private_key_jwt_assertion_carries_the_rfc7523_claims(
    certificate_pair: tuple[str, str, bytes],
) -> None:
    private_key_pem, certificate_pem, _ = certificate_pair
    credential = PrivateKeyJwtCredential(
        client_id=CLIENT_ID,
        private_key_pem=private_key_pem,
        certificate_pem=certificate_pem,
        lifetime=timedelta(minutes=5),
    )

    assertion = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW).body[
        "client_assertion"
    ]
    public_key = load_pem_x509_certificate(certificate_pem.encode("utf-8")).public_key()
    # La validazione temporale e' disattivata di proposito: `NOW` e' un istante
    # fissato per rendere deterministica l'asserzione su `exp`, e confrontarlo
    # con l'orologio della macchina renderebbe il test dipendente dalla data in
    # cui viene eseguito. Qui l'oggetto del test e' il contenuto dei claim.
    claims = jwt.decode(
        assertion,
        public_key,
        algorithms=["RS256"],
        audience=TOKEN_ENDPOINT,
        options={"verify_exp": False, "verify_nbf": False, "verify_iat": False},
    )

    assert claims["iss"] == CLIENT_ID
    assert claims["sub"] == CLIENT_ID
    assert claims["aud"] == TOKEN_ENDPOINT
    assert claims["exp"] == int((NOW + timedelta(minutes=5)).timestamp())
    assert claims["jti"]


@pytest.mark.unit
def test_private_key_jwt_header_carries_the_certificate_thumbprint(
    certificate_pair: tuple[str, str, bytes],
) -> None:
    """Entra individua la credenziale che ha firmato tramite `x5t`.

    Un `x5t` assente o disallineato produce `invalid_client` senza spiegare la
    causa, quindi vale la pena verificarlo qui.
    """
    private_key_pem, certificate_pem, fingerprint = certificate_pair
    credential = PrivateKeyJwtCredential(
        client_id=CLIENT_ID,
        private_key_pem=private_key_pem,
        certificate_pem=certificate_pem,
    )

    assertion = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW).body[
        "client_assertion"
    ]
    headers = jwt.get_unverified_header(assertion)

    assert headers["x5t"] == urlsafe_b64encode(fingerprint).decode("ascii").rstrip("=")
    assert headers["alg"] == "RS256"


@pytest.mark.unit
def test_private_key_jwt_generates_a_fresh_assertion_per_call(
    certificate_pair: tuple[str, str, bytes],
) -> None:
    private_key_pem, certificate_pem, _ = certificate_pair
    credential = PrivateKeyJwtCredential(
        client_id=CLIENT_ID,
        private_key_pem=private_key_pem,
        certificate_pem=certificate_pem,
    )

    first = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW).body["client_assertion"]
    second = credential.authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW).body[
        "client_assertion"
    ]

    assert first != second, "jti deve rendere ogni assertion irripetibile"


@pytest.mark.unit
def test_private_key_jwt_rejects_an_invalid_certificate() -> None:
    with pytest.raises(OidcClientCredentialError):
        PrivateKeyJwtCredential(
            client_id=CLIENT_ID,
            private_key_pem="-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----",
            certificate_pem="not a certificate",
        ).authenticate(token_endpoint=TOKEN_ENDPOINT, now=NOW)


@pytest.mark.unit
def test_private_key_jwt_requires_a_token_endpoint(
    certificate_pair: tuple[str, str, bytes],
) -> None:
    private_key_pem, certificate_pem, _ = certificate_pair
    credential = PrivateKeyJwtCredential(
        client_id=CLIENT_ID,
        private_key_pem=private_key_pem,
        certificate_pem=certificate_pem,
    )

    with pytest.raises(OidcClientCredentialError):
        credential.authenticate(token_endpoint="", now=NOW)
