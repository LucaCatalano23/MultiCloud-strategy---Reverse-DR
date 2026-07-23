from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from helios_shared.auth import AuthenticationError
from helios_shared.oidc import OidcJwtAuthenticator, OidcVerificationConfig


class StaticKeyProvider:
    def __init__(self, key: object) -> None:
        self.key = key

    async def get_signing_key(self, token: str) -> object:
        assert token
        return self.key


@pytest.mark.unit
async def test_oidc_verifier_validates_signature_issuer_audience_expiry_and_roles() -> None:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    issuer = "https://identity.example.test/tenant/v2.0"
    audience = "api://reverse-dr-helpdesk"
    token = jwt.encode(
        {
            "sub": "user-123",
            "iss": issuer,
            "aud": audience,
            "exp": datetime.now(UTC) + timedelta(minutes=5),
            "nbf": datetime.now(UTC) - timedelta(seconds=1),
            "roles": ["tickets.read"],
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )
    verifier = OidcJwtAuthenticator(
        OidcVerificationConfig(
            issuer=issuer,
            audience=audience,
            jwks_url="https://identity.example.test/.well-known/jwks.json",
            roles_claim="roles",
            algorithms=("RS256",),
        ),
        StaticKeyProvider(private_key.public_key()),
    )

    principal = await verifier.authenticate(token)

    assert principal.subject == "user-123"
    assert principal.permissions == frozenset({"tickets.read"})


@pytest.mark.unit
async def test_oidc_verifier_fails_closed_for_wrong_audience() -> None:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    issuer = "https://identity.example.test/tenant/v2.0"
    token = jwt.encode(
        {
            "sub": "user-123",
            "iss": issuer,
            "aud": "wrong-audience",
            "exp": datetime.now(UTC) + timedelta(minutes=5),
            "roles": [],
        },
        private_key,
        algorithm="RS256",
    )
    verifier = OidcJwtAuthenticator(
        OidcVerificationConfig(
            issuer=issuer,
            audience="api://reverse-dr-helpdesk",
            jwks_url="https://identity.example.test/jwks",
        ),
        StaticKeyProvider(private_key.public_key()),
    )

    with pytest.raises(AuthenticationError):
        await verifier.authenticate(token)
