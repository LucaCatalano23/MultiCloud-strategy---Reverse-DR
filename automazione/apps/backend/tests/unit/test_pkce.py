import pytest

from helios_bff.application.pkce import code_challenge, normalize_return_to


@pytest.mark.unit
def test_pkce_uses_rfc7636_s256_vector() -> None:
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert code_challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("/tickets", "/tickets"),
        ("/tickets?status=open", "/tickets?status=open"),
        ("https://evil.test", "/"),
        ("//evil.test", "/"),
        (r"/\evil.test", "/"),
        ("/%2f%2fevil.test", "/"),
        ("/%5cevil.test", "/"),
        ("/tickets\r\nLocation: https://evil.test", "/"),
        ("", "/"),
    ],
)
def test_return_to_is_restricted_to_local_absolute_paths(value: str, expected: str) -> None:
    assert normalize_return_to(value) == expected
