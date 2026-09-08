#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Legacy entry point retained for operators. The reconciler also prepares the
# local images and storage required by k3s-datacenter, so keeping a second
# deployment implementation here would allow the two paths to drift.
exec bash "${ROOT_DIR}/bin/reconcile-lxc-lab.sh"
