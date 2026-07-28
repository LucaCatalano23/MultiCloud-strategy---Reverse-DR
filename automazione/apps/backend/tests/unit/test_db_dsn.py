import pytest

from helios_shared.db import normalize_pg_dsn


@pytest.mark.unit
@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        # Il caso che faceva crashare i servizi: prefisso driver SQLAlchemy.
        (
            "postgresql+asyncpg://u:p@host:5432/helios",
            "postgresql://u:p@host:5432/helios",
        ),
        (
            "postgresql+psycopg://u:p@host:5432/helios",
            "postgresql://u:p@host:5432/helios",
        ),
        # Alias `postgres://` normalizzato allo schema canonico.
        ("postgres://u:p@host/helios", "postgresql://u:p@host/helios"),
        # DSN gia' corretto: invariato.
        ("postgresql://u:p@host:5432/helios", "postgresql://u:p@host:5432/helios"),
    ],
)
def test_normalizes_sqlalchemy_style_schemes_to_libpq(raw: str, expected: str) -> None:
    assert normalize_pg_dsn(raw) == expected


@pytest.mark.unit
def test_preserves_password_and_query_parameters() -> None:
    raw = "postgresql+asyncpg://helpdesk:p%40ss@postgres.helpdesk.svc:5432/helios?sslmode=require"
    assert normalize_pg_dsn(raw) == (
        "postgresql://helpdesk:p%40ss@postgres.helpdesk.svc:5432/helios?sslmode=require"
    )


@pytest.mark.unit
def test_leaves_key_value_conninfo_untouched() -> None:
    # libpq accetta anche la forma key=value: non deve essere alterata.
    raw = "host=postgres.helpdesk.svc dbname=helios user=helpdesk"
    assert normalize_pg_dsn(raw) == raw
