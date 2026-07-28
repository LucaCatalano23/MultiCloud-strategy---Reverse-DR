from __future__ import annotations

import re

# I servizi usano psycopg (AsyncConnectionPool), che accetta l'URI libpq
# `postgresql://` ma NON i prefissi con driver in stile SQLAlchemy
# (`postgresql+asyncpg://`, `postgresql+psycopg://`). Il resto del progetto usa
# per convenzione `postgresql+asyncpg://` nel Secret e lo converte con `sed` per
# psql/pg_dump; qui lo normalizziamo per psycopg, cosi' lo stesso valore di
# DATABASE_URL funziona sia per gli strumenti a riga di comando sia per i pool.
# Senza questa normalizzazione psycopg fallisce con "missing = after ..." perche'
# interpreta l'intera URL come una stringa di parametri key=value.
_DSN_SCHEME = re.compile(r"^(?:postgresql|postgres)(?:\+[a-zA-Z0-9]+)?://")


def normalize_pg_dsn(dsn: str) -> str:
    """Riduce lo schema di un DSN PostgreSQL alla forma accettata da libpq/psycopg.

    `postgresql+asyncpg://`, `postgresql+psycopg://` e l'alias `postgres://`
    diventano `postgresql://`; un DSN gia' corretto resta invariato; una stringa
    di connessione in formato key=value (senza schema URI) viene lasciata
    com'e', perche' libpq la accetta direttamente.
    """
    return _DSN_SCHEME.sub("postgresql://", dsn, count=1)
