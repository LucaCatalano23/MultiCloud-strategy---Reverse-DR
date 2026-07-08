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

La readiness dell'app e DR-aware:

- il primario risponde ready quando database e app sono sani;
- lo standby on-prem risponde live, ma non ready finche non esiste il marker `/dr-state/ready`;
- `scripts/promote-onprem.sh` crea il marker solo dopo il restore;
- K8GB, quando verra installato, dovra basarsi sulla readiness e non su un semplice ping.

Per warm standby lascia `ONPREM_STANDBY_REPLICAS=1` in `config.env`: il pod on-prem gira, ma non riceve traffico. Per cold standby usa `ONPREM_STANDBY_REPLICAS=0`: il controller lo avviera durante il failover.

## Flusso

1. `scripts/setup-cloud-sim.sh`: crea `cloud-k3s`, installa k3s e prepara backup directory.
2. `scripts/setup-onprem-k3s.sh`: installa k3s su `k3s-datacenter`.
3. `scripts/publish-git-truth.sh`: inizializza il repository applicativo su `git-server`.
4. `scripts/deploy-cloud-primary.sh`: deploy helpdesk primary su cloud.
5. `scripts/deploy-onprem-standby.sh`: deploy standby on-prem.
6. `scripts/backup-cloud.sh`: esegue backup dati dal cloud.
7. `scripts/failover-to-onprem.sh`: restore on-prem + promozione DR + DNS cutover.
8. `scripts/dr-controller.sh`: controller automatico che osserva il primario e lancia il failover.
9. `scripts/healthcheck.sh`: verifica stato cloud, on-prem e DNS.

## Esecuzione da WSL

```bash
cd /path/to/repository/automazione/helpdesk-dr
bash scripts/setup-cloud-sim.sh
bash scripts/setup-onprem-k3s.sh
bash scripts/publish-git-truth.sh
bash scripts/deploy-cloud-primary.sh
bash scripts/deploy-onprem-standby.sh
bash scripts/backup-cloud.sh
bash scripts/install-cloud-backup-timer.sh
```

Failover:

```bash
bash scripts/failover-to-onprem.sh
```

Failover automatico:

```bash
bash scripts/dr-controller.sh
```

Per una singola valutazione, utile in demo:

```bash
bash scripts/dr-controller.sh oneshot
```

Le soglie sono in `config.env`:

- `DR_CONTROLLER_FAILURE_THRESHOLD`: quanti check falliti prima del failover.
- `DR_CONTROLLER_INTERVAL_SECONDS`: intervallo tra i check.

## K8GB

I manifest PoC sono in `kubernetes/k8gb/`.

Scelta architetturale:

- K8GB gestisce DNS/GSLB e usa readiness/liveness per scegliere il sito.
- Il DR controller gestisce il processo stateful: backup restore, promozione e marker readiness.
- Questo evita che K8GB diventi un orchestratore applicativo, ma permette failover automatico anche in cold standby.

## RPO/RTO

- RPO: intervallo tra backup cloud, configurabile in `config.env`.
- RTO: tempo di restore on-prem + rollout app + aggiornamento DNS.

Questa simulazione e intenzionalmente cloud-provider neutral. Per AWS reale sostituirai `cloud-k3s` con una EC2 Ubuntu con k3s, mantenendo gli stessi manifest e runbook.
