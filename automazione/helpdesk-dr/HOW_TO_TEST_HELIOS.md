# Come testare Helios: dal primario AWS al Disaster Recovery on-premise

Questo runbook descrive un drill completo per Helios Desk: verifica del
primario AWS, attivazione del DR automatico, verifica del sito on-premise e
ritorno controllato al primario.

> **Non eseguire `bao operator init` durante un riavvio.** Se OpenBao è
> sigillato, va dissigillato con le share Shamir originali. Un nuovo `init`
> crea un vault diverso e rende inutilizzabili dati e token esistenti.

## 0. Prerequisiti e variabili

Aprire WSL, attendere LXD e portare su i container necessari:

```bash
sudo lxd waitready --timeout=60
lxc start --all
lxc list
```

Impostare la root del repository e verificare il laboratorio:

```bash
export REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT/automazione/lxc-lab"
bash healthcheck.sh
```

Il runbook usa questi nodi:

- `ansible-node`: controller e orchestratore del DR;
- `server-dns` (`10.10.2.53`): DNS split-horizon del lab;
- `k3s-datacenter` (`10.10.3.10`): sito DR;
- `vault-openbao`: OpenBao;
- `cloud-k3s`: dominio di guasto simulato del drill.

Il primario applicativo reale è AWS dietro un ALB. `cloud-k3s` non è una
copia dell'app cloud: è il failure domain locale che il drill spegne.

## 1. Ripristinare OpenBao dopo un riavvio (solo se è sealed)

Verificare lo stato:

```bash
lxc exec vault-openbao -- env BAO_ADDR=https://127.0.0.1:8200 \
  BAO_CACERT=/etc/openbao/tls/tls.crt \
  bao status
```

Se `Sealed: true`, eseguire il comando seguente e inserire **tre share Shamir
diverse**, una per volta:

```bash
lxc exec vault-openbao -- env BAO_ADDR=https://127.0.0.1:8200 \
  BAO_CACERT=/etc/openbao/tls/tls.crt \
  bao operator unseal
```

Ripetere la verifica di stato finché mostra `Sealed: false`. I token OpenBao
non funzionano finché il vault è sigillato; dopo l'unseal, un token precedente
funziona solo se non è stato revocato o non è scaduto.

## 2. Verificare il primario AWS

Assicurarsi che `kubectl` punti al cluster AWS e recuperare il DNS dell'ALB:

```bash
kubectl config current-context
export ALB_DNS="$(kubectl -n helios-desk get ingress helios-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export ALB_DNS="${ALB_DNS%.}"
printf 'ALB: %s\n' "$ALB_DNS"
test -n "$ALB_DNS"
```

Verificare la readiness del BFF cloud senza dipendere dal DNS del lab. Il
comando conserva hostname e SNI `heliospoc.terna.it`, ma apre la connessione
direttamente verso l'ALB:

```bash
curl --fail --silent --show-error \
  --connect-to "heliospoc.terna.it:443:${ALB_DNS}:443" \
  https://heliospoc.terna.it/health/ready
```

L'esito deve contenere almeno:

```json
{"status":"ready","service":"helios-bff"}
```

Se il certificato cloud è self-signed, aggiungere `--insecure` al comando
`curl`. Usarlo solo nel laboratorio.

### Aprire il primario con Firefox in WSL (temporaneo)

Firefox deve usare il nome canonico per TLS, cookie `__Host-*` e callback
OIDC. Per bypassare temporaneamente il DNS del lab, ricavare un IP corrente
dell'ALB e aggiungere una riga a `/etc/hosts`:

```bash
export ALB_IP="$(dig +short "$ALB_DNS" A | head -n 1)"
printf 'ALB IP: %s\n' "$ALB_IP"
test -n "$ALB_IP"
sudoedit /etc/hosts
```

Aggiungere manualmente questa riga (sostituendo il valore):

```text
<ALB_IP> heliospoc.terna.it
```

Verificare e aprire una finestra privata:

```bash
getent ahostsv4 heliospoc.terna.it
firefox --private-window 'https://heliospoc.terna.it'
```

Effettuare login sul primario e provare lettura/creazione di un ticket e
un'automazione. Prima del DR l'automazione deve usare `aws-lambda`.

> L'IP dell'ALB è dinamico. Questa riga è soltanto un override temporaneo e
> deve essere rimossa prima del test DR.

## 3. Preparare il controller automatico

Rimuovere l'override cloud da `/etc/hosts` prima di usare il DNS del lab:

```bash
sudoedit /etc/hosts
```

Eliminare la riga che contiene `heliospoc.terna.it`.

Verificare che OpenBao e il DR standby siano pronti:

```bash
cd "$REPO_ROOT/automazione/helpdesk-dr"
bash scripts/poc/ansible-run.sh poc/healthcheck
```

In `automazione/helpdesk-dr/config.env`, aggiungere o aggiornare queste
variabili senza sostituire il resto del file:

```dotenv
CLOUD_PROBE_MODE=https
CLOUD_TARGET_HOST=<DNS_ALB>
DR_AUTO_FAILOVER_ENABLED=true
DR_CONTROLLER_FAILURE_THRESHOLD=3
DR_CONTROLLER_INTERVAL_SECONDS=20
```

Sostituire `<DNS_ALB>` con il valore di `$ALB_DNS`. Per una demo più rapida è
possibile usare soglia `2` e intervallo `10`, da riportare poi ai valori
normali.

Pubblicare la configurazione sul nodo di controllo, validarla e controllare il
servizio:

```bash
bash scripts/poc/publish-git-truth.sh
bash scripts/poc/bootstrap-ansible-control-node.sh
bash scripts/poc/ansible-run.sh failover/dr-controller validate

lxc exec ansible-node -- systemctl status helpdesk-dr-controller.service --no-pager
```

In una shell separata, lasciare aperto il log del controller:

```bash
lxc exec ansible-node -- journalctl -u helpdesk-dr-controller.service -f
```

Prima del guasto il log deve mostrare `primary ready`. Un contatore come
`primary ready (380/2)` è normale: il valore dopo `/` è la soglia, mentre il
contatore non viene azzerato finché il primario resta sano.

## 4. Preparare il backup per il drill

Il failover richiede un dump PostgreSQL in formato custom (`.dump`) e il file
SHA-256 corrispondente nel mirror su `ansible-node`. Nel lab, dove il primario
non produce automaticamente il backup, crearne uno stand-in:

```bash
ts="$(date -u +%Y%m%dT%H%M%SZ)"
lxc exec k3s-datacenter -- kubectl -n helpdesk exec deploy/postgres -- \
  pg_dump -U helpdesk -Fc helios > "/tmp/${ts}.dump"
( cd /tmp && sha256sum "${ts}.dump" > "${ts}.dump.sha256" )
lxc exec ansible-node -- install -d /srv/helpdesk-dr-mirror/postgres
lxc file push "/tmp/${ts}.dump" \
  "ansible-node/srv/helpdesk-dr-mirror/postgres/${ts}.dump"
lxc file push "/tmp/${ts}.dump.sha256" \
  "ansible-node/srv/helpdesk-dr-mirror/postgres/${ts}.dump.sha256"
```

## 5. Simulare il guasto e osservare il DR automatico

Con il log del controller già aperto, spegnere il dominio di guasto:

```bash
lxc stop cloud-k3s --force
```

Non lanciare `oneshot` se si vuole testare il controller automatico. Dopo tre
failure consecutive, il log deve mostrare una sequenza simile:

```text
primary not ready (1/3)
primary not ready (2/3)
primary not ready (3/3)
Primary failed health threshold. Running the Ansible failover playbook...
```

Il controller esegue restore, preflight di OpenBao e lambda-dr, promozione dei
workload e aggiornamento DNS. Se il log riporta `DR state is already active`,
il sito è già stato promosso in un drill precedente: non viene avviato un
secondo restore.

## 6. Verificare il DR completato

Verificare stato, infrastruttura e DNS:

```bash
lxc exec ansible-node -- cat /var/lib/helpdesk-dr/mode
bash scripts/poc/ansible-run.sh poc/healthcheck
lxc exec k3s-datacenter -- kubectl -n helios-desk get deploy,pods
lxc exec k3s-datacenter -- kubectl -n lambda-dr get deploy,pods
dig @10.10.2.53 +short heliospoc.terna.it
```

Risultati attesi:

- lo stato è `dr`;
- healthcheck completato;
- i quattro deployment Helios sono pronti;
- i deployment `lambda-dr` sono pronti;
- il DNS del lab restituisce `10.10.3.10`.

Verificare anche dal client del lab:

```bash
lxc exec pc-dipendente1 -- curl -sk \
  https://heliospoc.terna.it/api/v1/session
```

Il risultato atteso è analogo a:

```json
{"authenticated":false,"user":null,"site":{"mode":"dr","identityProvider":"keycloak","name":"on-prem"}}
```

### Verifica funzionale con Firefox in WSL

Abilitare `server-dns` come resolver dell'host WSL (una volta sola richiede
`systemd=true` e `generateResolvConf=false` in `/etc/wsl.conf`, poi un
`wsl --shutdown` da PowerShell):

```bash
cd "$REPO_ROOT/automazione/lxc-lab"
sudo bash host-dns.sh enable
resolvectl flush-caches
dig @10.10.2.53 +short heliospoc.terna.it
resolvectl query heliospoc.terna.it
```

Entrambe le verifiche devono portare a `10.10.3.10`. Se `resolvectl` mostra
`Data from: synthetic` o un IP cloud, è ancora presente una riga
`heliospoc.terna.it` in `/etc/hosts`: rimuoverla con `sudoedit /etc/hosts` e
ripetere il flush.

Aprire una sessione pulita:

```bash
firefox --private-window 'https://heliospoc.terna.it'
```

Accettare il certificato self-signed, fare login con l'operatore DR Keycloak e
verificare:

1. dashboard con sito `dr`;
2. lettura e creazione di un ticket;
3. automazione con esecutore `lambda-dr` e runtime `lambda-rie-onprem`;
4. RTO misurato visibile nella dashboard, se la telemetria è stata registrata.

## 7. Ritorno al primario (cutback manuale)

Il cutback non è automatico: impedisce di spostare traffico e dati senza una
riconciliazione esplicita. Il comando `cutback-to-cloud.sh` del repository è
adatto al simulatore `cloud-k3s` (`10.20.0.10`), **non** al primario AWS dietro
ALB. Non usarlo per il cutback AWS.

### 7.1 Prerequisiti obbligatori

1. Il cloud deve rispondere dal nodo di controllo:

   ```bash
   lxc exec ansible-node -- curl --fail --silent --show-error \
     --connect-to "heliospoc.terna.it:443:${ALB_DNS}:443" \
     https://heliospoc.terna.it/health/ready
   ```

2. Se nel DR sono stati creati o modificati ticket, fermare le scritture sul
   DR ed eseguire la riconciliazione del database verso il primario con la
   procedura approvata per il database AWS. La PoC non implementa una replica
   inversa automatica: saltare questo passaggio causerebbe perdita di dati.

3. Fermare il controller durante il rientro:

   ```bash
   lxc exec ansible-node -- systemctl stop helpdesk-dr-controller.service
   ```

### 7.2 Ripubblicare il cloud nel DNS del lab

Il DNS primario deve essere un CNAME verso l'ALB, non un record A verso un suo
IP. Il CNAME vive nella zona padre `terna.it`; una zona più specifica
`heliospoc.terna.it`, creata dal DR, la sovrascrive e va quindi rimossa dalla
configurazione di Bind prima del rientro.

Accedere a Bind e rimuovere **solo** il blocco seguente da
`/etc/bind/named.conf.local`:

```conf
zone "heliospoc.terna.it" {
  type master;
  file "/etc/bind/db.heliospoc.terna.it";
};
```

Prima dell'editing creare una copia di sicurezza e aprire il file nel
container:

```bash
lxc exec server-dns -- cp /etc/bind/named.conf.local \
  /etc/bind/named.conf.local.before-aws-cutback
lxc exec server-dns -- vi /etc/bind/named.conf.local
```

Salvare il file dopo la rimozione del blocco. La rimozione è necessaria: Bind
sceglie la zona più specifica `heliospoc.terna.it` creata dal DR, che altrimenti
continuerebbe a prevalere sul CNAME nella zona padre `terna.it`.

Se nello stesso file non esiste già una definizione per `terna.it`, aggiungere
anche questo blocco prima di salvare:

```conf
zone "terna.it" {
  type master;
  file "/etc/bind/db.terna.it";
};
```

Poi riscrivere la zona padre con un valore ALB non vuoto e ricaricare Bind:

```bash
test -n "$ALB_DNS"
cat >/tmp/db.terna.it <<EOF
\$TTL 30
@ IN SOA server-dns.azienda.lan. admin.azienda.lan. (
  $(date +%s) 30 15 604800 30
)
@ IN NS server-dns.azienda.lan.
heliospoc IN CNAME ${ALB_DNS}.
EOF

lxc file push /tmp/db.terna.it server-dns/etc/bind/db.terna.it
lxc exec server-dns -- named-checkconf
lxc exec server-dns -- named-checkzone terna.it /etc/bind/db.terna.it
lxc exec server-dns -- systemctl reload named

dig @10.10.2.53 heliospoc.terna.it CNAME +noall +answer
dig @10.10.2.53 heliospoc.terna.it A +noall +answer
```

Procedere solo quando la risposta mostra il CNAME dell'ALB e i suoi indirizzi
risolti.

### 7.3 Demotare il DR e registrare il ritorno al primario

Quando i dati sono riconciliati e il DNS del lab porta al cloud, fermare i
workload DR:

```bash
lxc exec ansible-node -- helpdesk-dr failover/demote-onprem
```

Verificare che i workload applicativi on-prem siano a zero repliche:

```bash
lxc exec k3s-datacenter -- kubectl -n helios-desk get deploy
```

Solo dopo tutte le verifiche, aggiornare lo stato persistente e riavviare il
controller:

```bash
lxc exec ansible-node -- sh -lc '
  cd /opt/helpdesk-dr
  source scripts/common/lib.sh
  write_dr_state primary
'
lxc exec ansible-node -- systemctl start helpdesk-dr-controller.service
lxc exec ansible-node -- journalctl -u helpdesk-dr-controller.service -f
```

Il risultato atteso è `primary ready`. Ripetere quindi la sezione 2 per una
nuova verifica del primario o la sezione 5 per un nuovo drill.

## 8. Ripristinare il DNS normale di WSL (opzionale)

Quando si termina il test, disabilitare il resolver del lab sull'host WSL:

```bash
cd "$REPO_ROOT/automazione/lxc-lab"
sudo bash host-dns.sh disable
```
