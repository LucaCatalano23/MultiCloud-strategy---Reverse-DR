from __future__ import annotations

from typing import Any, Mapping

from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool

from helios_bff.domain.auth import BrowserSession, OAuthTransaction
from helios_shared.auth import Principal


class PostgresAuthStore:
    def __init__(self, pool: AsyncConnectionPool[Any]) -> None:
        self._pool = pool

    async def save_transaction(self, transaction: OAuthTransaction) -> None:
        async with self._pool.connection() as connection:
            await connection.execute(
                """
                INSERT INTO oauth_transactions (
                  state_hash, nonce, encrypted_code_verifier, return_to, expires_at
                ) VALUES (%s, %s, %s, %s, %s)
                """,
                (
                    transaction.state_hash,
                    transaction.nonce,
                    transaction.encrypted_code_verifier,
                    transaction.return_to,
                    transaction.expires_at,
                ),
            )

    async def consume_transaction(self, state_hash: str) -> OAuthTransaction | None:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                """
                DELETE FROM oauth_transactions
                WHERE state_hash = %s
                RETURNING state_hash, nonce, encrypted_code_verifier, return_to, expires_at
                """,
                (state_hash,),
            )
            row = await cursor.fetchone()
        return _transaction_from_row(row) if row else None

    async def save_session(self, session: BrowserSession) -> None:
        async with self._pool.connection() as connection:
            await connection.execute(
                """
                INSERT INTO bff_sessions (
                  session_id_hash, principal, encrypted_access_token, csrf_hash, expires_at
                ) VALUES (%s, %s, %s, %s, %s)
                """,
                (
                    session.session_id_hash,
                    Jsonb(_principal_to_dict(session.principal)),
                    session.encrypted_access_token,
                    session.csrf_hash,
                    session.expires_at,
                ),
            )

    async def get_session(self, session_id_hash: str) -> BrowserSession | None:
        async with self._pool.connection() as connection:
            cursor = await connection.execute(
                """
                SELECT session_id_hash, principal, encrypted_access_token, csrf_hash, expires_at
                FROM bff_sessions
                WHERE session_id_hash = %s
                """,
                (session_id_hash,),
            )
            row = await cursor.fetchone()
        return _session_from_row(row) if row else None

    async def delete_session(self, session_id_hash: str) -> None:
        async with self._pool.connection() as connection:
            await connection.execute(
                "DELETE FROM bff_sessions WHERE session_id_hash = %s",
                (session_id_hash,),
            )

    async def ping(self) -> bool:
        async with self._pool.connection() as connection:
            await connection.execute("SELECT 1")
        return True


def _principal_to_dict(principal: Principal) -> dict[str, Any]:
    return {
        "subject": principal.subject,
        "issuer": principal.issuer,
        "audience": list(principal.audience),
        "displayName": principal.display_name,
        "email": principal.email,
        "permissions": sorted(principal.permissions),
    }


def _principal_from_dict(value: Mapping[str, Any]) -> Principal:
    return Principal(
        subject=str(value["subject"]),
        issuer=str(value["issuer"]),
        audience=tuple(str(item) for item in value["audience"]),
        display_name=value.get("displayName"),
        email=value.get("email"),
        permissions=frozenset(str(item) for item in value["permissions"]),
    )


def _transaction_from_row(row: Mapping[str, Any]) -> OAuthTransaction:
    return OAuthTransaction(
        state_hash=row["state_hash"],
        nonce=row["nonce"],
        encrypted_code_verifier=row["encrypted_code_verifier"],
        return_to=row["return_to"],
        expires_at=row["expires_at"],
    )


def _session_from_row(row: Mapping[str, Any]) -> BrowserSession:
    return BrowserSession(
        session_id_hash=row["session_id_hash"],
        principal=_principal_from_dict(row["principal"]),
        encrypted_access_token=row["encrypted_access_token"],
        csrf_hash=row["csrf_hash"],
        expires_at=row["expires_at"],
    )
