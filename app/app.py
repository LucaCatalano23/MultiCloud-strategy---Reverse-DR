"""Servizio dimostrativo cloud-agnostic per produzione e Island Mode."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache

import boto3
import httpx
import psycopg
from botocore.config import Config as BotoConfig
from fastapi import FastAPI, HTTPException, Response, status


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Variabile d'ambiente obbligatoria non definita: {name}")
    return value


@dataclass(frozen=True)
class Settings:
    mode: str
    database_host: str
    database_port: int
    database_name: str
    database_user: str
    database_password: str
    storage_endpoint: str | None
    storage_bucket: str
    storage_access_key: str | None
    storage_secret_key: str | None
    storage_region: str
    idp_provider: str
    idp_issuer_url: str
    idp_client_id: str
    idp_client_secret: str

    @classmethod
    def from_environment(cls) -> "Settings":
        mode = os.getenv("APP_MODE", "production").strip().lower()
        if mode not in {"production", "island"}:
            raise RuntimeError("APP_MODE deve essere 'production' oppure 'island'")
        idp_provider = _required("IDP_PROVIDER").lower()
        if idp_provider not in {"entra", "keycloak"}:
            raise RuntimeError("IDP_PROVIDER deve essere 'entra' oppure 'keycloak'")
        return cls(
            mode=mode,
            database_host=_required("DATABASE_HOST"),
            database_port=int(os.getenv("DATABASE_PORT", "5432")),
            database_name=_required("DATABASE_NAME"),
            database_user=_required("DATABASE_USER"),
            database_password=_required("DATABASE_PASSWORD"),
            storage_endpoint=os.getenv("OBJECT_STORAGE_ENDPOINT") or None,
            storage_bucket=_required("OBJECT_STORAGE_BUCKET"),
            storage_access_key=os.getenv("OBJECT_STORAGE_ACCESS_KEY") or None,
            storage_secret_key=os.getenv("OBJECT_STORAGE_SECRET_KEY") or None,
            storage_region=os.getenv("OBJECT_STORAGE_REGION", "eu-west-1"),
            idp_provider=idp_provider,
            idp_issuer_url=_required("IDP_ISSUER_URL").rstrip("/"),
            idp_client_id=_required("IDP_CLIENT_ID"),
            idp_client_secret=_required("IDP_CLIENT_SECRET"),
        )

    @property
    def database_dsn(self) -> str:
        return (
            f"host={self.database_host} port={self.database_port} "
            f"dbname={self.database_name} user={self.database_user} "
            f"password={self.database_password} connect_timeout=3"
        )


@lru_cache
def settings() -> Settings:
    return Settings.from_environment()


def storage_client(config: Settings):
    options: dict[str, object] = {
        "service_name": "s3",
        "region_name": config.storage_region,
        "config": BotoConfig(signature_version="s3v4", connect_timeout=3, read_timeout=3),
    }
    if config.storage_endpoint:
        options["endpoint_url"] = config.storage_endpoint
    if config.storage_access_key and config.storage_secret_key:
        options["aws_access_key_id"] = config.storage_access_key
        options["aws_secret_access_key"] = config.storage_secret_key
    return boto3.client(**options)


app = FastAPI(title="Reverse DR Agnostic App", version="1.0.0")


@app.get("/health", status_code=status.HTTP_204_NO_CONTENT)
def health() -> Response:
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/ready")
def ready() -> dict[str, str]:
    config = settings()
    failures: list[str] = []
    try:
        with psycopg.connect(config.database_dsn) as connection:
            connection.execute("SELECT 1")
    except Exception:
        failures.append("database")
    try:
        storage_client(config).head_bucket(Bucket=config.storage_bucket)
    except Exception:
        failures.append("object-storage")
    try:
        response = httpx.get(
            f"{config.idp_issuer_url}/.well-known/openid-configuration", timeout=3.0
        )
        response.raise_for_status()
    except Exception:
        failures.append("identity-provider")
    if failures:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"status": "not-ready", "dependencies": failures},
        )
    return {"status": "ready", "mode": config.mode}


@app.get("/runtime")
def runtime() -> dict[str, str]:
    """Espone solo metadati non sensibili utili alla verifica del failover."""
    config = settings()
    return {
        "mode": config.mode,
        "storage_backend": "custom-s3-compatible" if config.storage_endpoint else "default-s3",
        "identity_issuer": config.idp_issuer_url,
        "identity_provider": config.idp_provider,
    }
