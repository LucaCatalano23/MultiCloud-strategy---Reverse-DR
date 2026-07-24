from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Literal, Mapping

# Chiavi scritte dai due produttori reali della telemetria DR. Restano costanti
# condivise perche' i writer vivono fuori da questo processo (CronJob di backup
# lato cloud, `record-dr-telemetry.sh` invocato da failover.yml lato on-prem):
# un rename qui senza rename la' produrrebbe silenziosamente "non disponibile".
BACKUP_METRIC = "backup.last_success"
FAILOVER_METRIC = "failover.last_promotion"

DrMetricStatus = Literal["ok", "warning", "critical", "unknown"]


@dataclass(frozen=True, slots=True)
class DrTelemetryRecord:
    metric: str
    recorded_at: datetime
    duration_seconds: int | None
    detail: Mapping[str, Any]


def classify(value_seconds: int | None, target_seconds: int) -> DrMetricStatus:
    """Confronta una misura con il suo obiettivo dichiarato.

    `unknown` non e' un errore: e' l'esito onesto quando nessun backup e'
    ancora stato prodotto o nessun failover e' mai stato eseguito. La soglia
    di `critical` e' il doppio del target, cosi' un ritardo singolo resta un
    warning e non viene confuso con un meccanismo fermo.
    """
    if value_seconds is None:
        return "unknown"
    if value_seconds <= target_seconds:
        return "ok"
    if value_seconds <= target_seconds * 2:
        return "warning"
    return "critical"


def age_seconds(recorded_at: datetime, now: datetime) -> int:
    """Eta' di una misura, mai negativa.

    Un clock skew fra il pod che scrive e quello che legge produrrebbe una
    eta' negativa: viene normalizzata a 0 invece di mostrare un RPO impossibile.
    """
    return max(0, int((now - recorded_at).total_seconds()))
