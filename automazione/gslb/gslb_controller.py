from __future__ import annotations

import ipaddress
import json
import logging
import os
import signal
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class Site(str, Enum):
    PRODUCTION = "production"
    DR = "dr"


@dataclass(frozen=True)
class Policy:
    failure_threshold: int
    recovery_threshold: int
    auto_failback: bool

    def choose(
        self,
        active: Site,
        production_failures: int,
        production_successes: int,
        dr_successes: int,
    ) -> Site:
        if (
            active is Site.PRODUCTION
            and production_failures >= self.failure_threshold
            and dr_successes >= self.recovery_threshold
        ):
            return Site.DR
        if (
            active is Site.DR
            and self.auto_failback
            and production_successes >= self.recovery_threshold
        ):
            return Site.PRODUCTION
        return active


@dataclass(frozen=True)
class AppConfig:
    name: str
    host_header: str
    production_ip: str
    dr_ip: str
    production_health_url: str
    dr_health_url: str

    @classmethod
    def from_dict(cls, data: dict) -> "AppConfig":
        return cls(
            name=data["name"],
            host_header=data["host_header"],
            production_ip=_validated_ip(data["production_ip"]),
            dr_ip=_validated_ip(data["dr_ip"]),
            production_health_url=data["production_health_url"],
            dr_health_url=data["dr_health_url"]
        )


@dataclass(frozen=True)
class Config:
    zone_path: Path
    apps_config_path: Path
    status_path: Path
    check_interval_seconds: float
    request_timeout_seconds: float
    dns_ttl_seconds: int
    initial_site: Site
    policy: Policy

    @classmethod
    def from_environment(cls) -> "Config":
        return cls(
            zone_path=Path(os.getenv("GSLB_ZONE_PATH", "/var/lib/gslb/db.reverse-dr.local")),
            apps_config_path=Path(os.getenv("GSLB_APPS_CONFIG_PATH", "/var/lib/gslb/apps.json")),
            status_path=Path(os.getenv("GSLB_STATUS_PATH", "/var/lib/gslb/status.json")),
            check_interval_seconds=_positive_float("GSLB_CHECK_INTERVAL_SECONDS", 10),
            request_timeout_seconds=_positive_float("GSLB_REQUEST_TIMEOUT_SECONDS", 3),
            dns_ttl_seconds=_positive_int("GSLB_DNS_TTL_SECONDS", 30),
            initial_site=Site(os.getenv("GSLB_INITIAL_SITE", Site.PRODUCTION.value)),
            policy=Policy(
                failure_threshold=_positive_int("GSLB_FAILURE_THRESHOLD", 3),
                recovery_threshold=_positive_int("GSLB_RECOVERY_THRESHOLD", 3),
                auto_failback=_boolean("GSLB_AUTO_FAILBACK", True),
            ),
        )

    def load_apps(self) -> list[AppConfig]:
        if not self.apps_config_path.exists():
            logging.warning(f"File {self.apps_config_path} non trovato. Nessuna app configurata.")
            return []
        try:
            with open(self.apps_config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return [AppConfig.from_dict(app) for app in data.get("apps", [])]
        except Exception as e:
            logging.error(f"Errore caricamento {self.apps_config_path}: {e}")
            return []


class AppState:
    def __init__(self, initial_site: Site):
        self.active = initial_site
        self.production_failures = 0
        self.production_successes = 0
        self.dr_successes = 0
        self.dr_failures = 0

    def record_health(self, production_healthy: bool, dr_healthy: bool) -> None:
        self.production_successes = self.production_successes + 1 if production_healthy else 0
        self.production_failures = 0 if production_healthy else self.production_failures + 1
        self.dr_successes = self.dr_successes + 1 if dr_healthy else 0
        self.dr_failures = 0 if dr_healthy else self.dr_failures + 1

    def to_dict(self) -> dict:
        return {
            "active_site": self.active.value,
            "production": {
                "consecutive_successes": self.production_successes,
                "consecutive_failures": self.production_failures,
            },
            "dr": {
                "consecutive_successes": self.dr_successes,
                "consecutive_failures": self.dr_failures,
            }
        }


class GslbController:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.apps: list[AppConfig] = []
        self.app_states: dict[str, AppState] = {}
        self._load_config_and_state()
        self.serial = int(time.time())
        self.running = True

    def _load_config_and_state(self) -> None:
        self.apps = self.config.load_apps()
        
        # Load previous states if available
        saved_states = {}
        try:
            if self.config.status_path.exists():
                document = json.loads(self.config.status_path.read_text(encoding="utf-8"))
                saved_states = document.get("apps", {})
        except Exception as e:
            logging.warning(f"Impossibile leggere stato precedente: {e}")

        # Initialize current states
        for app in self.apps:
            state = AppState(self.config.initial_site)
            if app.name in saved_states:
                try:
                    state.active = Site(saved_states[app.name].get("active_site", self.config.initial_site.value))
                except ValueError:
                    pass
            self.app_states[app.name] = state

    def run(self) -> None:
        self._publish(force=True, reason="startup")
        while self.running:
            started_at = time.monotonic()
            
            # Reload apps dynamically (simulating config reload)
            self._load_config_and_state()
            
            changed = False
            reasons = []

            for app in self.apps:
                state = self.app_states[app.name]
                
                production_healthy = _is_healthy(
                    app.production_health_url,
                    app.host_header,
                    self.config.request_timeout_seconds,
                )
                dr_healthy = _is_healthy(
                    app.dr_health_url,
                    app.host_header,
                    self.config.request_timeout_seconds,
                )
                state.record_health(production_healthy, dr_healthy)

                selected = self.config.policy.choose(
                    state.active,
                    state.production_failures,
                    state.production_successes,
                    state.dr_successes,
                )
                
                if selected is not state.active:
                    reason = f"{app.name}: health-policy {state.active.value}->{selected.value}"
                    logging.warning(reason)
                    state.active = selected
                    changed = True
                    reasons.append(reason)

            if changed:
                self._publish(force=True, reason=", ".join(reasons))
            else:
                self._write_status(reason="health-check")

            elapsed = time.monotonic() - started_at
            time.sleep(max(0.1, self.config.check_interval_seconds - elapsed))

    def stop(self, *_: object) -> None:
        self.running = False

    def _publish(self, force: bool, reason: str) -> None:
        if not force and self.config.zone_path.exists():
            return
        self.serial = max(self.serial + 1, int(time.time()))
        
        app_records = []
        for app in self.apps:
            state = self.app_states[app.name]
            address = app.production_ip if state.active is Site.PRODUCTION else app.dr_ip
            app_records.append((app.name, address))
            
        zone = _render_zone(self.serial, self.config.dns_ttl_seconds, app_records)
        _atomic_write(self.config.zone_path, zone)
        self._write_status(reason=reason)

    def _write_status(self, reason: str) -> None:
        status = {
            "reason": reason,
            "updated_at_epoch": int(time.time()),
            "apps": {app_name: state.to_dict() for app_name, state in self.app_states.items()}
        }
        _atomic_write(self.config.status_path, json.dumps(status, indent=2, sort_keys=True) + "\n")


def _render_zone(serial: int, ttl: int, app_records: list[tuple[str, str]]) -> str:
    lines = [
        f"$ORIGIN reverse-dr.local.",
        f"$TTL {ttl}",
        f"@ IN SOA ns1.reverse-dr.local. admin.reverse-dr.local. (",
        f"    {serial} ; serial",
        f"    60 ; refresh",
        f"    30 ; retry",
        f"    86400 ; expire",
        f"    {ttl} ; negative cache TTL",
        f")",
        f"@ IN NS ns1.reverse-dr.local.",
        f"ns1 IN A 127.0.0.1"
    ]
    for name, address in app_records:
        lines.append(f"{name} IN A {address}")
    lines.append("")
    return "\n".join(lines)


def _is_healthy(url: str, host_header: str, timeout: float) -> bool:
    request = urllib.request.Request(
        url,
        headers={"Host": host_header, "User-Agent": "reverse-dr-gslb/1.0"},
        method="GET",
    )
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


def _validated_ip(value: str) -> str:
    return str(ipaddress.ip_address(value))


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


def _boolean(name: str, default: bool) -> bool:
    value = os.getenv(name, str(default)).strip().lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"{name} deve essere un booleano")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    controller = GslbController(Config.from_environment())
    signal.signal(signal.SIGTERM, controller.stop)
    signal.signal(signal.SIGINT, controller.stop)
    controller.run()


if __name__ == "__main__":
    main()
