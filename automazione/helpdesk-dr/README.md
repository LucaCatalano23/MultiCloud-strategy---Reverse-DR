# Helpdesk Reverse DR Lab

Questo modulo simula un disaster recovery inverso cloud -> on-premise.

## Ruoli

- `cloud-k3s`: macchina esterna alla rete aziendale LXC, sempre dentro WSL/LXD. Ospita il cluster Kubernetes primario.
- `k3s-datacenter`: nodo on-prem nella rete aziendale LXC. Ospita il cluster Kubernetes di DR.
- `git-server`: punto di verita per applicativo, manifest e runbook.
- `server-dns`: DNS aziendale. In stato normale punta `helpdesk.azienda.lan` al cloud; in DR lo punta on-prem.
- `ansible-node`: orchestratore operativo per backup, restore e cutover.

## Architettura

```text
cloud-k3s
  helpdesk-api primary
  postgres primary
  backup cronjob -> /srv/helpdesk-backups

on-prem k3s-datacenter
  helpdesk-api standby/DR
  postgres restored from backup

server-dns
  helpdesk.azienda.lan -> cloud ingress, normal mode
  helpdesk.azienda.lan -> on-prem ingress, DR mode

dr-controller
  osserva il primario
  esegue restore + promote quando il primario resta KO
  abilita readiness on-prem solo dopo il restore
```

Il traffico normale va verso il cloud simulato. Il failover promuove on-prem e aggiorna DNS.

## Struttura

```text
app/                       sorgente FastAPI helpdesk
manifests/kubernetes/      manifest Kubernetes e overlay kustomize
scripts/common/            funzioni comuni usate dai runbook
scripts/deploy/            deploy primary cloud e standby on-prem
scripts/backup/            backup manuale e timer del primary cloud
scripts/restore/           restore dei dati sul sito on-prem
scripts/failover/          promozione DR, cutback e controller automatico
scripts/poc/               configurazione PoC, bootstrap ansible e healthcheck
```

Non ci sono wrapper nella root di `scripts/`: ogni comando va eseguito dal percorso della sua categoria.

La readiness dell'app e DR-aware:

- il primario risponde ready quando database e app sono sani;
- lo standby on-prem risponde live, ma non ready finche non esiste il marker `/dr-state/ready`;
- `scripts/failover/promote-onprem.sh` crea il marker solo dopo il restore;
- K8GB, quando verra installato, dovra basarsi sulla readiness e non su un semplice ping.

L'endpoint `/dr-status` mostra quale sito sta servendo la richiesta:

```bash
curl http://helpdesk.azienda.lan/dr-status
```

In normal mode risponde con `mode=normal` e `served_by=cloud-sim`. Dopo failover risponde con `mode=dr`, `active_site=on-prem` e `served_by=on-prem`.

Per warm standby lascia `ONPREM_STANDBY_REPLICAS=1` in `config.env`: il pod on-prem gira, ma non riceve traffico. Per cold standby usa `ONPREM_STANDBY_REPLICAS=0`: il controller lo avviera durante il failover.

## Flusso

1. `scripts/poc/setup-cloud-sim.sh`: crea `cloud-k3s`, installa k3s e prepara backup directory.
2. `scripts/poc/setup-onprem-k3s.sh`: installa k3s su `k3s-datacenter`.
3. `scripts/poc/publish-git-truth.sh`: inizializza il repository applicativo su `git-server`.
4. `scripts/deploy/deploy-cloud-primary.sh`: deploy helpdesk primary su cloud.
5. `scripts/deploy/deploy-onprem-standby.sh`: deploy standby on-prem.
6. `scripts/backup/backup-cloud.sh`: esegue backup dati dal cloud.
7. `scripts/failover/failover-to-onprem.sh`: restore on-prem + promozione DR + DNS cutover.
8. `scripts/failover/dr-controller.sh`: controller automatico che osserva il primario e lancia il failover.
9. `scripts/poc/healthcheck.sh`: verifica stato cloud, on-prem e DNS.

## Esecuzione da WSL

```bash
cd /path/to/repository/automazione/helpdesk-dr
bash scripts/poc/setup-cloud-sim.sh
bash scripts/poc/setup-onprem-k3s.sh
bash scripts/poc/publish-git-truth.sh
bash scripts/deploy/deploy-cloud-primary.sh
bash scripts/deploy/deploy-onprem-standby.sh
bash scripts/backup/backup-cloud.sh
bash scripts/backup/install-cloud-backup-timer.sh
```

## Esecuzione da ansible-node

Per rendere `ansible-node` il control node reale, pubblica prima il repository su `git-server`, clona il source of truth su `ansible-node` e abilita il client LXD verso il socket dell'host:

```bash
bash scripts/poc/bootstrap-ansible-control-node.sh
```

Dopo il bootstrap, i runbook possono partire da `ansible-node`:

```bash
lxc exec ansible-node -- helpdesk-dr poc/healthcheck
lxc exec ansible-node -- helpdesk-dr backup/backup-cloud
lxc exec ansible-node -- helpdesk-dr failover/failover-to-onprem
```

Oppure, dalla WSL, usando il comando remoto su `ansible-node`:

```bash
bash scripts/poc/ansible-run.sh poc/healthcheck
bash scripts/poc/ansible-run.sh backup/backup-cloud
bash scripts/poc/ansible-run.sh failover/failover-to-onprem
```

In questo modello `git-server` resta il punto di verita e `ansible-node` diventa l'esecutore operativo dei runbook.

Failover:

```bash
bash scripts/failover/failover-to-onprem.sh
```

Failover automatico:

```bash
bash scripts/failover/dr-controller.sh
```

Per una singola valutazione, utile in demo:

```bash
bash scripts/failover/dr-controller.sh oneshot
```

Le soglie sono in `config.env`:

- `DR_CONTROLLER_FAILURE_THRESHOLD`: quanti check falliti prima del failover.
- `DR_CONTROLLER_INTERVAL_SECONDS`: intervallo tra i check.

## K8GB

I manifest PoC sono in `manifests/kubernetes/k8gb/`.

Scelta architetturale:

- K8GB gestisce DNS/GSLB e usa readiness/liveness per scegliere il sito.
- Il DR controller gestisce il processo stateful: backup restore, promozione e marker readiness.
- Questo evita che K8GB diventi un orchestratore applicativo, ma permette failover automatico anche in cold standby.

## RPO/RTO

- RPO: intervallo tra backup cloud, configurabile in `config.env`.
- RTO: tempo di restore on-prem + rollout app + aggiornamento DNS.

Questa simulazione e intenzionalmente cloud-provider neutral. Per AWS reale sostituirai `cloud-k3s` con una EC2 Ubuntu con k3s, mantenendo gli stessi manifest e runbook.
