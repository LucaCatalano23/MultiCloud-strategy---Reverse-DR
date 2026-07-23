from datetime import UTC, datetime, timedelta

import pytest

from helios_shared.auth import AuthenticationError, AuthorizationError, Principal


@pytest.mark.unit
def test_principal_normalizes_oidc_claims_and_roles() -> None:
    claims = {
        "sub": "user-123",
        "iss": "https://login.microsoftonline.com/tenant/v2.0",
        "aud": "api://reverse-dr-helpdesk",
        "exp": int((datetime.now(UTC) + timedelta(minutes=5)).timestamp()),
        "name": "Ada Lovelace",
        "preferred_username": "ada@example.test",
        "roles": ["tickets.read", "tickets.write"],
    }

    principal = Principal.from_claims(claims, roles_claim="roles")

    assert principal.subject == "user-123"
    assert principal.audience == ("api://reverse-dr-helpdesk",)
    assert principal.email == "ada@example.test"
    assert principal.permissions == frozenset({"tickets.read", "tickets.write"})
    principal.require("tickets.read")
    with pytest.raises(AuthorizationError):
        principal.require("automation.execute")


@pytest.mark.unit
def test_principal_supports_keycloak_nested_role_claim() -> None:
    principal = Principal.from_claims(
        {
            "sub": "user-123",
            "iss": "https://keycloak.example.test/realms/helios",
            "aud": ["api://reverse-dr-helpdesk"],
            "exp": int((datetime.now(UTC) + timedelta(minutes=5)).timestamp()),
            "realm_access": {"roles": ["tickets.read"]},
        },
        roles_claim="realm_access.roles",
    )

    assert principal.permissions == frozenset({"tickets.read"})


@pytest.mark.unit
@pytest.mark.parametrize(
    "claims",
    [
        {},
        {"sub": "u", "iss": "i", "aud": "a", "exp": 1, "roles": "admin"},
        {"sub": "", "iss": "i", "aud": "a", "exp": 1, "roles": []},
    ],
)
def test_principal_rejects_missing_or_ambiguous_claims(claims: dict[str, object]) -> None:
    with pytest.raises(AuthenticationError):
        Principal.from_claims(claims, roles_claim="roles")
