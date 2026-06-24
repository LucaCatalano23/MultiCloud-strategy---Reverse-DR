#!/usr/bin/env bash
set -Eeuo pipefail

APPROVED_BY="${1:-}"
CONTROL_DIR="${IDENTITY_CONTROL_DIR:-/var/lib/identity-control}"
STATUS_PATH="${CONTROL_DIR}/status.json"
APPROVAL_PATH="${CONTROL_DIR}/approve-entra.json"

if [[ -z "${APPROVED_BY}" ]]; then
  echo "Uso: $0 <identità-operatore>" >&2
  exit 64
fi

python3 - "${STATUS_PATH}" "${APPROVAL_PATH}" "${APPROVED_BY}" <<'PY'
import json
import os
import sys
import tempfile
import time
from pathlib import Path

status_path = Path(sys.argv[1])
approval_path = Path(sys.argv[2])
approved_by = sys.argv[3].strip()

try:
    status = json.loads(status_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit("Stato identity non disponibile.")

expected = "entra_recovered_awaiting_approval"
if status.get("state") != expected:
    raise SystemExit(f"Failback non approvabile nello stato {status.get('state')!r}.")

document = {
    "approved_at_epoch": int(time.time()),
    "approved_by": approved_by,
    "expected_state": expected,
}
approval_path.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary_name = tempfile.mkstemp(prefix=".approve-entra.", dir=approval_path.parent)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary_name, approval_path)
print(f"Failback verso Entra ID approvato da {approved_by}.")
PY
