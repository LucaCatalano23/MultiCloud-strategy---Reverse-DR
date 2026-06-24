from __future__ import annotations

import hashlib
import json
import logging
import os
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class Provider(str, Enum):
    ENTRA = "entra"
    KEYCLOAK = "keycloak"


class IdentityState(str, Enum):
    ENTRA_ACTIVE = "entra_active"
    KEYCLOAK_ACTIVE = "keycloak_active"
    ENTRA_RECOVERED_AWAITING_APPROVAL = "entra_recovered_awaiting_approval"

    @property
    def provider(self) -> Provider:
        if self is IdentityState.ENTRA_ACTIVE:
            return Provider.ENTRA
        return Provider.KEYCLOAK


@dataclass(frozen=True)
class Policy:
    failure_threshold: int
    recovery_threshold: int

    def choose(
        self,
        state: IdentityState,
        entra_failures: int,
        entra_successes: int,
        keycloak_successes: int,
        failback_approved: bool,
    ) -> IdentityState:
        if state is IdentityState.ENTRA_ACTIVE:
            if (
                entra_failures >= self.failure_threshold
                and keycloak_successes >= self.recovery_threshold
            ):
                return IdentityState.KEYCLOAK_ACTIVE
            return state

        if state is IdentityState.KEYCLOAK_ACTIVE:
            if entra_successes >= self.recovery_threshold:
                return IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL
            return state

        if entra_failures > 0:
            return IdentityState.KEYCLOAK_ACTIVE
        if failback_approved and entra_successes >= self.recovery_threshold:
            return IdentityState.ENTRA_ACTIVE
        return state


@dataclass(frozen=True)
class ProviderConfig:
    issuer_url: str
    client_id: str
    client_secret: str


@dataclass(frozen=True)
class Config:
    status_path: Path
    approval_path: Path
    namespace: str
    deployment: str
    entra: ProviderConfig
    keycloak: ProviderConfig
    entra_health_url: str
    keycloak_health_url: str
    check_interval_seconds: float
    request_timeout_seconds: float
    approval_ttl_seconds: int
    policy: Policy

    @classmethod
    def from_environment(cls) -> "Config":
        return cls(
            status_path=Path(os.getenv("IDENTITY_STATUS_PATH", "/var/lib/identity/status.json")),
            approval_path=Path(os.getenv("IDENTITY_APPROVAL_PATH", "/var/lib/identity/approve-entra.json")),
            namespace=os.getenv("IDENTITY_K8S_NAMESPACE", "reverse-dr"),
            deployment=os.getenv("IDENTITY_K8S_DEPLOYMENT", "reverse-dr-app"),
            entra=ProviderConfig(
                issuer_url=_required("ENTRA_ID_ISSUER_URL").rstrip("/"),
                client_id=_required("ENTRA_ID_CLIENT_ID"),
                client_secret=_required("ENTRA_ID_CLIENT_SECRET"),
            ),
            keycloak=ProviderConfig(
                issuer_url=_required("KEYCLOAK_ISSUER_URL").rstrip("/"),
                client_id=_required("KEYCLOAK_CLIENT_ID"),
                client_secret=_required("KEYCLOAK_CLIENT_SECRET"),
            ),
            entra_health_url=_required("ENTRA_ID_HEALTH_URL"),
            keycloak_health_url=_required("KEYCLOAK_HEALTH_URL"),
            check_interval_seconds=_positive_float("IDENTITY_CHECK_INTERVAL_SECONDS", 10),
            request_timeout_seconds=_positive_float("IDENTITY_REQUEST_TIMEOUT_SECONDS", 5),
            approval_ttl_seconds=_positive_int("IDENTITY_APPROVAL_TTL_SECONDS", 900),
            policy=Policy(
                failure_threshold=_positive_int("IDENTITY_FAILURE_THRESHOLD", 3),
                recovery_threshold=_positive_int("IDENTITY_RECOVERY_THRESHOLD", 3),
            ),
        )


class KubernetesPublisher:
    def __init__(self, config: Config) -> None:
        self.config = config

    def publish(self, provider: Provider, values: ProviderConfig) -> bool:
        current = self._current_configuration()
        configuration_hash = hashlib.sha256(
            "\0".join(
                (provider.value, values.issuer_url, values.client_id, values.client_secret)
            ).encode("utf-8")
        ).hexdigest()
        if current == (provider.value, values.issuer_url, configuration_hash):
            return True
        config_map = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "identity-provider-active",
                "namespace": self.config.namespace,
                "labels": {"app.kubernetes.io/managed-by": "identity-failover-controller"},
            },
            "data": {
                "IDP_PROVIDER": provider.value,
                "IDP_ISSUER_URL": values.issuer_url,
                "IDP_CONFIGURATION_HASH": configuration_hash,
            },
        }
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "identity-provider-credentials",
                "namespace": self.config.namespace,
                "labels": {"app.kubernetes.io/managed-by": "identity-failover-controller"},
            },
            "type": "Opaque",
            "stringData": {
                "IDP_CLIENT_ID": values.client_id,
                "IDP_CLIENT_SECRET": values.client_secret,
            },
        }
        if not self._apply(config_map) or not self._apply(secret):
            return False

        patch = {
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {
                            "reverse-dr.local/identity-switched-at": str(int(time.time())),
                            "reverse-dr.local/identity-provider": provider.value,
                        }
                    }
                }
            }
        }
        result = self._kubectl(
            "patch",
            "deployment",
            self.config.deployment,
            "--type=merge",
            "--patch",
            json.dumps(patch, separators=(",", ":")),
        )
        if result.returncode != 0:
            if "NotFound" in result.stderr:
                logging.info("Deployment non ancora presente; configurazione identity preparata")
                return True
            logging.error("Impossibile riavviare il deployment dopo il cambio identity: %s", result.stderr.strip())
            return False
        logging.warning("Provider identity pubblicato: %s", provider.value)
        return True

    def _current_configuration(self) -> tuple[str, str, str] | None:
        result = self._kubectl(
            "get",
            "configmap",
            "identity-provider-active",
            "-o",
            "json",
        )
        if result.returncode != 0:
            return None
        try:
            data = json.loads(result.stdout)["data"]
            return (
                data["IDP_PROVIDER"],
                data["IDP_ISSUER_URL"],
                data["IDP_CONFIGURATION_HASH"],
            )
        except (json.JSONDecodeError, KeyError, TypeError):
            return None

    def _apply(self, document: dict[str, object]) -> bool:
        result = self._kubectl("apply", "-f", "-", input_text=json.dumps(document))
        if result.returncode != 0:
            logging.info("API Kubernetes non ancora disponibile: %s", result.stderr.strip())
            return False
        return True

    def _kubectl(self, *arguments: str, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["kubectl", "--namespace", self.config.namespace, *arguments],
            input=input_text,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )


class IdentityFailoverController:
    def __init__(self, config: Config, publisher: KubernetesPublisher) -> None:
        self.config = config
        self.publisher = publisher
        self.state = self._restore_state()
        self.last_transition = self._restore_last_transition()
        self.entra_successes = 0
        self.entra_failures = 0
        self.keycloak_successes = 0
        self.keycloak_failures = 0
        self.running = True

    def run(self) -> None:
        self._write_status(reason="startup")
        while self.running:
            started_at = time.monotonic()
            entra_healthy = _is_healthy(
                self.config.entra_health_url, self.config.request_timeout_seconds
            )
            keycloak_healthy = _is_healthy(
                self.config.keycloak_health_url, self.config.request_timeout_seconds
            )
            self._record_health(entra_healthy, keycloak_healthy)

            approval = self._valid_approval()
            selected = self.config.policy.choose(
                self.state,
                self.entra_failures,
                self.entra_successes,
                self.keycloak_successes,
                approval is not None,
            )
            reason = self._transition_reason(self.state, selected)
            if selected is not self.state:
                previous = self.state
                logging.warning("Cambio stato identity: %s -> %s", self.state.value, selected.value)
                self.state = selected
                self.last_transition = {
                    "from": previous.value,
                    "to": selected.value,
                    "reason": reason,
                    "at_epoch": int(time.time()),
                }
                if approval is not None and selected is IdentityState.ENTRA_ACTIVE:
                    self.last_transition["approved_by"] = approval["approved_by"]

            provider_values = (
                self.config.entra
                if self.state.provider is Provider.ENTRA
                else self.config.keycloak
            )
            published = self.publisher.publish(self.state.provider, provider_values)
            if approval is not None and self.state is IdentityState.ENTRA_ACTIVE and published:
                logging.warning(
                    "Failback Entra approvato da %s alle %s",
                    approval["approved_by"],
                    approval["approved_at_epoch"],
                )
                self.config.approval_path.unlink(missing_ok=True)

            self._write_status(reason=reason, configuration_published=published)
            elapsed = time.monotonic() - started_at
            time.sleep(max(0.1, self.config.check_interval_seconds - elapsed))

    def stop(self, *_: object) -> None:
        self.running = False

    def _record_health(self, entra_healthy: bool, keycloak_healthy: bool) -> None:
        self.entra_successes = self.entra_successes + 1 if entra_healthy else 0
        self.entra_failures = 0 if entra_healthy else self.entra_failures + 1
        self.keycloak_successes = self.keycloak_successes + 1 if keycloak_healthy else 0
        self.keycloak_failures = 0 if keycloak_healthy else self.keycloak_failures + 1

    def _valid_approval(self) -> dict[str, object] | None:
        if self.state is not IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL:
            return None
        try:
            approval = json.loads(self.config.approval_path.read_text(encoding="utf-8"))
            approved_at = int(approval["approved_at_epoch"])
            approved_by = str(approval["approved_by"]).strip()
            expected_state = approval["expected_state"]
        except (FileNotFoundError, KeyError, ValueError, TypeError, json.JSONDecodeError):
            return None
        if not approved_by or expected_state != self.state.value:
            return None
        if int(time.time()) - approved_at > self.config.approval_ttl_seconds:
            logging.error("Approvazione failback Entra scaduta")
            self.config.approval_path.unlink(missing_ok=True)
            return None
        return approval

    def _restore_state(self) -> IdentityState:
        try:
            document = json.loads(self.config.status_path.read_text(encoding="utf-8"))
            return IdentityState(document["state"])
        except (FileNotFoundError, KeyError, ValueError, json.JSONDecodeError):
            return IdentityState.ENTRA_ACTIVE

    def _restore_last_transition(self) -> dict[str, object] | None:
        try:
            document = json.loads(self.config.status_path.read_text(encoding="utf-8"))
            transition = document.get("last_transition")
            return transition if isinstance(transition, dict) else None
        except (FileNotFoundError, ValueError, json.JSONDecodeError):
            return None

    def _write_status(self, reason: str, configuration_published: bool = False) -> None:
        status = {
            "state": self.state.value,
            "active_provider": self.state.provider.value,
            "awaiting_approval": self.state
            is IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL,
            "configuration_published": configuration_published,
            "reason": reason,
            "last_transition": self.last_transition,
            "entra": {
                "consecutive_successes": self.entra_successes,
                "consecutive_failures": self.entra_failures,
            },
            "keycloak": {
                "consecutive_successes": self.keycloak_successes,
                "consecutive_failures": self.keycloak_failures,
            },
            "updated_at_epoch": int(time.time()),
        }
        _atomic_write(self.config.status_path, json.dumps(status, indent=2, sort_keys=True) + "\n")

    @staticmethod
    def _transition_reason(previous: IdentityState, selected: IdentityState) -> str:
        if previous is selected:
            return "health-policy"
        if selected is IdentityState.KEYCLOAK_ACTIVE:
            return "entra-unavailable"
        if selected is IdentityState.ENTRA_RECOVERED_AWAITING_APPROVAL:
            return "entra-recovered-awaiting-approval"
        return "entra-failback-approved"


def _is_healthy(url: str, timeout: float) -> bool:
    request = urllib.request.Request(url, headers={"User-Agent": "identity-failover/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, TimeoutError, ValueError):
        return False


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_name, path)
        os.chmod(path, 0o644)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"{name} è obbligatoria")
    return value


def _positive_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} deve essere maggiore di zero")
    return value


def _positive_float(name: str, default: float) -> float:
    value = float(os.getenv(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} deve essere maggiore di zero")
    return value


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = Config.from_environment()
    controller = IdentityFailoverController(config, KubernetesPublisher(config))
    signal.signal(signal.SIGTERM, controller.stop)
    signal.signal(signal.SIGINT, controller.stop)
    controller.run()


if __name__ == "__main__":
    main()
