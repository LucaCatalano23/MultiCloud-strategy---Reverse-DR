#!/usr/bin/env bash
# Builda le quattro immagini applicative Helios e le importa nel containerd di
# k3s-datacenter.
#
# Perche' esiste: i Deployment on-prem referenziano immagini `:local` con
# imagePullPolicy: IfNotPresent, ma nessun registry le serve. Questo script e'
# l'equivalente on-prem del push in ECR del sito primario: costruisce gli
# artefatti dall'host e li rende disponibili al cluster di laboratorio.
#
# Va eseguito dall'host WSL. Usa docker per la build e lxc per l'import, quindi
# NON richiede un kubeconfig ne' i segreti DR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${APPS_DIR}/backend"
FRONTEND_DIR="${APPS_DIR}/frontend"

NODE="${ONPREM_K3S_NAME:-k3s-datacenter}"
ARCHIVE="${APPS_DIR}/.state/helios-images.tar"

command -v docker >/dev/null 2>&1 || { echo "docker e' richiesto." >&2; exit 1; }
command -v lxc >/dev/null 2>&1 || { echo "lxc e' richiesto." >&2; exit 1; }

# Nome immagine = valore atteso dai manifest in infra/onprem/application/workloads.yaml.
# Se un nome cambia qui va cambiato la' nello stesso momento, altrimenti il pod
# resta in ImagePullBackOff.
echo "Build helios-bff:local..."
docker build -t helios-bff:local -f "${BACKEND_DIR}/services/bff/Dockerfile" "${BACKEND_DIR}"
echo "Build helios-ticket-service:local..."
docker build -t helios-ticket-service:local -f "${BACKEND_DIR}/services/ticket-service/Dockerfile" "${BACKEND_DIR}"
echo "Build helios-automation-service:local..."
docker build -t helios-automation-service:local -f "${BACKEND_DIR}/services/automation-service/Dockerfile" "${BACKEND_DIR}"
echo "Build reverse-dr/helios-desk-frontend:local..."
docker build -t reverse-dr/helios-desk-frontend:local "${FRONTEND_DIR}"

mkdir -p "$(dirname "${ARCHIVE}")"
echo "Esportazione immagini in un unico archivio..."
docker save \
  helios-bff:local \
  helios-ticket-service:local \
  helios-automation-service:local \
  reverse-dr/helios-desk-frontend:local \
  -o "${ARCHIVE}"

# Il container deve essere avviato e k3s pronto prima del push: lxc file push non
# avvia il container, e k3s ctr ha bisogno del socket containerd, che esiste solo
# dopo l'avvio di k3s. Stesso vincolo di deploy-lambda-onprem.sh.
if [ "$(lxc list "${NODE}" -c s --format csv 2>/dev/null | tr '[:lower:]' '[:upper:]')" != "RUNNING" ]; then
  echo "Avvio ${NODE}..."
  lxc start "${NODE}"
fi

echo "Attesa di k3s su ${NODE}..."
for _ in $(seq 1 60); do
  if lxc exec "${NODE}" -- k3s kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
if ! lxc exec "${NODE}" -- k3s kubectl get nodes >/dev/null 2>&1; then
  echo "k3s non e' diventato pronto su ${NODE}." >&2
  exit 1
fi

# /var/tmp e non /tmp: non e' soggetto a pulizia automatica ne' montato come
# tmpfs, quindi l'archivio sopravvive fino all'import.
echo "Import delle immagini nel containerd di ${NODE}..."
lxc file push "${ARCHIVE}" "${NODE}/var/tmp/helios-images.tar"
lxc exec "${NODE}" -- k3s ctr images import /var/tmp/helios-images.tar
lxc exec "${NODE}" -- rm -f /var/tmp/helios-images.tar
rm -f "${ARCHIVE}"

echo "Immagini Helios importate in ${NODE}."
