# Helpdesk Reverse DR Lab

> La procedura aggiornata con orchestrazione Ansible è in [`../RUNBOOK_SCENARIO_REALE.md`](../RUNBOOK_SCENARIO_REALE.md). Le sezioni storiche sotto descrivono la prima versione della PoC e non rappresentano più l'ordine completo di provisioning.
>
> **Monolite `helpdesk-api` rimosso.** La prima applicazione della PoC era un monolite FastAPI senza frontend (`app/`), servito da `manifests/kubernetes/base/helpdesk.yaml` e deployato sul cloud simulato da `scripts/deploy/deploy-cloud-primary.sh`. È stato eliminato: l'unica applicazione del progetto è ora Helios (`automazione/apps` + `automazione/infra/onprem`). Di conseguenza sono spariti anche l'overlay `manifests/kubernetes/cloud/`, `scripts/deploy/build-helpdesk-image.sh` e l'endpoint `/dr-status` del monolite. Questo modulo conserva **solo** l'orchestrazione DR (Ansible, restore, promozione, DNS) e il PostgreSQL condiviso, che sono usati dalla generazione corrente.
>
> **Cloud-primary-via-LocalStack dismesso.** La simulazione AWS (EKS/S3/Lambda) tramite LocalStack e' stata rimossa: il progetto non simula piu' l'infrastruttura AWS via LocalStack, che resta coperta solo dalla generazione corrente con AWS reale (`automazione/infra/aws`). Di conseguenza il backup automatico del primary cloud verso S3 e il mirror on-prem non sono piu' popolati automaticamente: `scripts/restore/restore-onprem.sh` continua a funzionare, ma serve un backup gia' presente in `BACKUP_MIRROR_DIR` sull'`ansible-node`.

Questo modulo simula un disaster recovery inverso cloud -> on-premise.

## Ruoli

- `cloud-k3s`: macchina esterna alla rete aziendale LXC, sempre dentro WSL/LXD. Ospita il cluster Kubernetes primario. Dopo la rimozione del monolite non vi gira più alcuna applicazione: resta come **failure domain** che il drill spegne.
- `k3s-datacenter`: nodo on-prem nella rete aziendale LXC. Ospita il cluster Kubernetes di DR e i workload Helios.
- `git-server`: punto di verita per applicativo, manifest e runbook.
- `server-dns`: DNS split-horizon del lab. In stato normale punta `heliospoc.ggg.it` al cloud; in DR lo punta on-prem.
- `ansible-node`: orchestratore operativo per backup, restore e cutover.

## Architettura

```text
cloud-k3s
  data plane Kubernetes (failure domain del drill)
  nessuna applicazione: il primario reale e' AWS EKS (automazione/infra/aws)

on-prem k3s-datacenter
  helios-web / helios-bff / helios-ticket-service / helios-automation-service
  keycloak + postgres identita (namespace helios-identity)
  postgres applicativo restored from backup (namespace helpdesk, database helios)

server-dns
  heliospoc.ggg.it -> cloud ingress, normal mode
  heliospoc.ggg.it -> on-prem ingress, DR mode

dr-controller
  osserva il data plane primario
  esegue restore + promote quando il primario resta KO
  abilita readiness on-prem solo dopo il restore
```

## Struttura

```text
manifests/kubernetes/      namespace e PostgreSQL condiviso (overlay on-prem)
scripts/common/            funzioni comuni usate dai runbook
scripts/deploy/            deploy dello standby on-prem e del runtime lambda-dr
scripts/backup/            backup manuale e timer del primary cloud
scripts/restore/           restore dei dati sul sito on-prem
scripts/failover/          promozione DR, cutback, telemetria e controller automatico
scripts/poc/               configurazione PoC, bootstrap ansible e healthcheck
```

Non ci sono wrapper nella root di `scripts/`: ogni comando va eseguito dal percorso della sua categoria.

La readiness è DR-aware e vive ora nei workload Helios:

- i quattro Deployment Helios restano a `replicas: 0` a riposo (`applicationReplicasAtRest: 0`);
- `scripts/failover/promote-onprem.sh` imposta `DR_ACTIVE=true`, riconfigura il BFF su Keycloak e scala i workload solo dopo restore e preflight identità;
- se il namespace `helios-desk` non esiste, la promozione **fallisce esplicitamente**: non esiste più un fallback su un'applicazione legacy;
- K8GB, quando verra installato, dovra basarsi sulla readiness e non su un semplice ping.

Quale sito stia servendo la richiesta si legge da `GET /api/v1/session` del BFF (campo `site`) e dalla colonna operativa della dashboard, che mostra anche RPO e RTO misurati. L'endpoint `/dr-status` apparteneva al monolite e non esiste più.

## Flusso

1. `scripts/poc/setup-cloud-sim.sh`: crea `cloud-k3s`, installa k3s e prepara backup directory.
2. `scripts/poc/setup-onprem-k3s.sh`: installa k3s su `k3s-datacenter`.
3. `scripts/poc/publish-git-truth.sh`: inizializza il repository applicativo su `git-server`.
4. `scripts/deploy/deploy-lambda-onprem.sh`: runtime `lambda-dr` e function `helpdesk-ticket-processor`.
5. `scripts/deploy/deploy-onprem-standby.sh`: deploy standby on-prem (Helios + Keycloak warm).
6. `scripts/failover/run-ansible-failover.sh`: playbook Ansible per restore, preflight Lambda, promozione, DNS cutover e registrazione dell'RTO misurato.
7. `scripts/failover/dr-controller.sh`: controller automatico che osserva il primario e lancia il failover.
8. `scripts/poc/healthcheck.sh`: verifica stato cloud, on-prem e DNS.

Il backup periodico del primary cloud verso S3 (via LocalStack) e il relativo mirror on-prem sono stati rimossi insieme a LocalStack; vedi la nota a inizio file.

## Esecuzione da WSL

```bash
cd /path/to/repository/automazione/helpdesk-dr
bash scripts/poc/setup-cloud-sim.sh
bash scripts/poc/setup-onprem-k3s.sh
bash scripts/poc/publish-git-truth.sh
bash scripts/deploy/deploy-lambda-onprem.sh
bash scripts/deploy/deploy-onprem-standby.sh
```

I segreti del sito DR vanno prima scritti in OpenBao con `automazione/infra/vault/scripts/seed-secrets.sh`; nel cluster li materializza External Secrets Operator. Lo schema applicativo va applicato con `apply-migrations.sh`.

## Esecuzione da ansible-node

Per rendere `ansible-node` il control node reale, configura prima il probe nel
`config.env` locale. Il bootstrap fallisce chiuso finché lo stato non è stato
inizializzato dal deploy dello standby e non imposti esplicitamente:

```bash
DR_AUTO_FAILOVER_ENABLED=true
```

Nel cloud reale aggiungi anche il target ALB descritto sotto. Pubblica quindi il
repository su `git-server`, clona il source of truth su `ansible-node` e abilita
il client LXD verso il socket dell'host. Il bootstrap disabilita il daemon LXD
annidato nello snap, perché sul control node serve soltanto il client:

```bash
bash scripts/poc/bootstrap-ansible-control-node.sh
```

Dopo il bootstrap, i runbook possono partire da `ansible-node`:

```bash
lxc exec ansible-node -- helpdesk-dr poc/healthcheck
lxc exec ansible-node -- helpdesk-dr failover/run-ansible-failover
```

Oppure, dalla WSL, usando il comando remoto su `ansible-node`:

```bash
bash scripts/poc/ansible-run.sh poc/healthcheck
bash scripts/poc/ansible-run.sh failover/run-ansible-failover
```

In questo modello `git-server` resta il punto di verita e `ansible-node` diventa l'esecutore operativo dei runbook.

Failover:

```bash
bash scripts/poc/ansible-run.sh failover/run-ansible-failover
```

Failover automatico:

```bash
systemctl status helpdesk-dr-controller.service --no-pager
journalctl -u helpdesk-dr-controller.service -f
```

Il servizio viene installato, abilitato e avviato da
`bootstrap-ansible-control-node.sh`: non serve lasciare una shell aperta e il
controller riparte automaticamente con `ansible-node`. Tre failure consecutive
con i default correnti avviano da sole restore, preflight, promozione e cutover
DNS. Il ritorno al cloud resta manuale perche' richiede riconciliazione dei dati.

### Target del cloud: hostname ALB, non IP

Nel laboratorio il target resta `CLOUD_K3S_IP=10.20.0.10`. Su AWS non salvare
gli IP restituiti da `nslookup`: i nodi di un Application Load Balancer possono
cambiare. Recupera invece il DNS name pubblicato dall'Ingress:

```bash
kubectl -n helios-desk get ingress helios-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

Inserisci il risultato nel `config.env` locale distribuito ad `ansible-node`:

```bash
CLOUD_PROBE_MODE=https
CLOUD_TARGET_HOST=k8s-helios-xxxxxxxx.eu-west-1.elb.amazonaws.com
DR_AUTO_FAILOVER_ENABLED=true
```

Il controller usa `curl --connect-to`: apre la connessione verso il DNS name
dell'ALB, ma conserva `heliospoc.ggg.it` come Host e TLS SNI. Cosi' il probe
continua a osservare direttamente AWS anche quando il DNS canonico punta gia'
al DR. Per il traffico utente configura `heliospoc.ggg.it` come CNAME verso
l'ALB se e' un record nella zona padre `ggg.it`, oppure come Route 53 Alias A;
non configurare mai un A record con gli IP correnti dell'ALB.

### Senza ACM pubblico: self-signed HTTPS (preferito)

Se non puoi avere un certificato ACM *validato pubblicamente* ma puoi importare
un self-signed in ACM (`aws acm import-certificate`, gia' cio' che fa
`provision.sh`), l'edge resta **HTTPS**: i cookie `__Host-*`, il CSRF e la
callback OIDC continuano a funzionare. E' la strada preferita quando manca un
ACM pubblico. In `config.env`, puntando anche direttamente all'IP dell'ALB:

```bash
CLOUD_PROBE_MODE=https
CLOUD_TARGET_HOST=<IP o DNS name dell'ALB>
CLOUD_TARGET_INSECURE=true   # oppure CLOUD_TARGET_CA_FILE=/percorso/al/self-signed.crt
DR_AUTO_FAILOVER_ENABLED=true
```

Il cert self-signed non e' nel trust store, quindi la verifica va rilassata:
`CLOUD_TARGET_CA_FILE` fissa quel cert come CA da fidare (piu' severo, richiede
di distribuirlo ad `ansible-node`), oppure `CLOUD_TARGET_INSECURE=true` salta la
verifica (piu' semplice). Sono mutuamente esclusivi. Con `--cacert` il SAN del
cert deve includere `heliospoc.ggg.it`. Anche qui il probe usa `--connect-to`
verso l'IP tenendo `heliospoc.ggg.it` come Host/SNI. L'IP dell'ALB e' dinamico e
va aggiornato a mano quando cambia.

### Ultima spiaggia: probe HTTP puro (nessun cert sull'ALB)

Solo se non puoi caricare **nessun** cert sull'ALB (ne' ACM, ne' self-signed
importato, ne' IAM server certificate). Punta all'IP in chiaro:

```bash
CLOUD_PROBE_MODE=http
CLOUD_TARGET_HOST=<IP pubblico dell'ALB>
CLOUD_TARGET_PORT=80
DR_AUTO_FAILOVER_ENABLED=true
```

Come in `https`, il probe usa `curl --connect-to`: apre la connessione verso
l'IP indicato ma conserva `heliospoc.ggg.it` come Host, cosi' la regola
host-based dell'Ingress instrada comunque verso `helios-bff`.

Limiti dichiarati di questa modalita', accettati consapevolmente:

- **Rompe il login utente reale**: su HTTP in chiaro il browser rifiuta i cookie
  `__Host-*` e la callback OIDC non e' same-origin HTTPS. Va bene solo per il
  probe di readiness / ambienti non-produzione; per gli utenti reali preferisci
  il self-signed HTTPS sopra.
- **Nessuna verifica TLS**: il traffico del probe e' in chiaro.
- **L'IP dell'ALB non e' stabile**: AWS puo' cambiarlo; va aggiornato a mano nel
  `config.env` di `ansible-node`.
- **L'ALB deve esporre l'app su HTTP senza `ssl-redirect`**: con
  `alb.ingress.kubernetes.io/ssl-redirect` attivo il listener `:80` risponde
  `301` e il probe (che pretende `200`) fallirebbe, innescando un failover
  falso. Usa il manifest opt-in `infra/aws/kubernetes/ingress-http-only.yaml`.

Per una singola valutazione, utile in demo:

```bash
bash scripts/poc/ansible-run.sh failover/dr-controller oneshot
```

Le soglie sono in `config.env`:

- `DR_CONTROLLER_FAILURE_THRESHOLD`: quanti check falliti prima del failover.
- `DR_CONTROLLER_INTERVAL_SECONDS`: intervallo tra i check.
- `DR_CONTROLLER_RETRY_COOLDOWN_SECONDS`: attesa dopo una promozione fallita.
- `DR_AUTO_FAILOVER_ENABLED`: interlock esplicito richiesto prima che il
  bootstrap possa avviare il servizio.

## K8GB

I manifest PoC sono in `manifests/kubernetes/k8gb/`.

Scelta architetturale:

- K8GB gestisce DNS/GSLB e usa readiness/liveness per scegliere il sito.
- Il DR controller gestisce il processo stateful: backup restore, promozione e flag dichiarativo di readiness.
- Questo evita che K8GB diventi un orchestratore applicativo, ma permette failover automatico anche in cold standby.

## RPO/RTO

Le due metriche sono ora **misurate** e visibili in dashboard; la definizione completa, con ciò che includono e ciò che non includono, è in [`../RUNBOOK_SCENARIO_REALE.md`](../RUNBOOK_SCENARIO_REALE.md#rpo-e-rto-misurabili).

- RPO: eta' dell'ultimo backup registrato dal CronJob (`backup.last_success`). Nel lab dipende ancora da quando è stato prodotto il backup presente in `BACKUP_MIRROR_DIR` su `ansible-node`, perché il timer automatico di backup/mirror è stato rimosso insieme a LocalStack.
- RTO: durata misurata del playbook di failover (`failover.last_promotion`): restore on-prem + preflight + rollout + aggiornamento DNS, escluso il tempo di rilevamento del guasto.

La generazione corrente (`automazione/apps`, `automazione/infra`) copre EKS, S3, IAM e Lambda su AWS reale; questa PoC legacy non simula piu' quelle API via LocalStack.
