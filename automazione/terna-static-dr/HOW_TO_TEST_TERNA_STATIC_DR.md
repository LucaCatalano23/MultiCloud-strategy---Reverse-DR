# Come testare Terna Static DR: dal sito pubblico al fallback locale

Questo runbook esegue un drill completo della PoC Terna Static DR: verifica del
sito pubblico, preparazione della copia statica on-premise, failover DNS
automatico, verifica da Firefox in WSL e ritorno manuale al sito pubblico.

La PoC è una copia informativa point-in-time di `www.terna.it`: non replica
login, form, API live o pagine interne. Durante il DR, il grafico di carico è
l'ultima acquisizione valida oppure un placeholder locale esplicito; non è un
dato realtime.

## 0. Prerequisiti

Aprire WSL, attendere LXD, avviare i container e verificare il laboratorio:

```bash
sudo lxd waitready --timeout=60
while IFS=, read -r node state; do
  if [ "$state" != RUNNING ]; then
    lxc start "$node"
  fi
done < <(lxc list --format csv -c ns)
lxc list

export REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT/automazione/lxc-lab"
bash healthcheck.sh
```

Tutti i comandi di questo documento vanno eseguiti dall'host WSL, salvo dove
è indicato esplicitamente un nodo LXC. Se il comando `lxc` cerca il socket
`lxd-user/unix.socket` oppure restituisce `connection refused`, usare il client
di sistema:

```bash
sudo /snap/bin/lxc list
```

Negli esempi successivi `lxc` presuppone che l'utente WSL possa già accedere al
daemon LXD. In caso contrario, sostituirlo sempre con `sudo /snap/bin/lxc`.

I nodi coinvolti sono:

- `router-edge`: rappresenta la connettività WAN;
- `server-dns` (`10.10.2.53`): DNS del lab;
- `ansible-node`: controller del failover;
- `k3s-datacenter` (`10.10.3.10`): ingress e fallback statico.

## 1. Preparare e verificare il fallback statico

Il setup completo riconcilia automaticamente Terna Static DR. Eseguire
`automazione/lxc-lab/setup.sh` quando bisogna creare o riallineare anche la
topologia LXC. Dopo un normale aggiornamento del solo sottoprogetto Terna non
serve rilanciare il setup completo: usare il reconcile idempotente, che
aggiorna fetcher, unit systemd, namespace/pod e controller:

```bash
cd "$REPO_ROOT"
bash automazione/terna-static-dr/bin/reconcile-lxc-lab.sh
```

In alternativa, partendo dalla directory del sottoprogetto:

```bash
cd "$REPO_ROOT/automazione/terna-static-dr/bin"
bash reconcile-lxc-lab.sh
```

Il solo deploy Kubernetes, senza riallineare fetcher e controller, è disponibile
con il comando seguente ma non sostituisce il reconcile dopo un aggiornamento
del repository:

```bash
cd "$REPO_ROOT"
bash automazione/terna-static-dr/bin/deploy-static-pod.sh
```

Per raccogliere un log completo quando il reconcile fallisce:

```bash
cd "$REPO_ROOT/automazione/terna-static-dr/bin"
set -o pipefail
bash -x reconcile-lxc-lab.sh 2>&1 | tee /tmp/terna-reconcile.log
echo "exit code: ${PIPESTATUS[0]}"
tail -n 120 /tmp/terna-reconcile.log
```

Il grafico viene catturato dal report pubblico Terna tramite Chromium; non
sono richieste credenziali né file segreti. Il reconcile installa Chromium sul
nodo K3s se non è già presente. Il fetcher attende l'evento Power BI
`rendered`, usa una porta DevTools effimera e ritenta in tre profili Chrome
isolati; in caso di indisponibilità conserva l'ultimo PNG valido. Il processo
Chrome gira con l'identità non privilegiata `nobody` sul nodo Linux.

Controllare pod, timer e bundle locale:

```bash
lxc exec k3s-datacenter -- kubectl -n terna-static-dr get deployment,pods
lxc exec k3s-datacenter -- systemctl status terna-static-origin-fetch.timer --no-pager
lxc exec k3s-datacenter -- test -s /srv/terna-static-dr/static/current/index.html
lxc exec k3s-datacenter -- test -s /srv/terna-static-dr/static/current/manifest.json
lxc exec k3s-datacenter -- test -f /srv/terna-static-dr/static/current/.bundle-v1
lxc exec k3s-datacenter -- test -s /srv/terna-static-dr/static/current/dr/load-chart/index.html
lxc exec k3s-datacenter -- sh -ec 'chart=/srv/terna-static-dr/static/current/dr/load-chart; test -f "$chart/.load-chart-v1" || test -f "$chart/.load-chart-placeholder-v1"'
```

Controllare anche che il fetcher e l'unit systemd installati siano realmente
quelli del repository corrente:

```bash
lxc exec k3s-datacenter -- test -x \
  /usr/local/lib/terna-static-dr/build-load-screenshot.py
lxc exec k3s-datacenter -- test -r \
  /usr/local/lib/terna-static-dr/load_chart_capture.py
lxc exec k3s-datacenter -- test -r \
  /usr/local/lib/terna-static-dr/chrome_devtools_capture.py

lxc exec k3s-datacenter -- \
  grep -F '/run/terna-static-dr/origin-fetch.lock' \
  /usr/local/lib/terna-static-dr/terna-static-origin-fetch.sh

lxc exec k3s-datacenter -- systemctl cat terna-static-origin-fetch.service
```

Nell'unit devono essere presenti `RuntimeDirectory=terna-static-dr` e
`RuntimeDirectoryMode=0750`.

Verificare direttamente l'ingress DR senza modificare DNS:

```bash
curl --fail --silent --show-error -H 'Host: terna.it' \
  http://10.10.3.10/health
curl --fail --silent --show-error -H 'Host: terna.it' \
  http://10.10.3.10/dr/load-chart/index.html >/dev/null
```

Questi controlli sono bloccanti: il controller rifiuta di cambiare DNS se il
pod o lo snapshot non sono pronti.

### 1.1 Verificare l'ultimo snapshot

Il comando seguente mostra il bundle puntato da `current`, l'istante di
acquisizione, la modalità di cattura e lo stato del grafico:

```bash
lxc exec k3s-datacenter -- sh -ec '
  current=/srv/terna-static-dr/static/current
  chart="$current/dr/load-chart"

  echo "Snapshot: $(readlink -f "$current")"
  echo "Captured at: $(cat "$current/captured-at")"
  echo "Capture mode: $(cat "$current/capture-mode")"

  if test -f "$chart/.load-chart-v1"; then
    echo "Load chart: dati reali"
  elif test -f "$chart/.load-chart-placeholder-v1"; then
    echo "Load chart: placeholder valido per il DR"
  else
    echo "Load chart: marker mancante"
    exit 1
  fi

  grep -E "\"(status|reason_code|message|data_date|captured_at)\"" \
    "$chart/data.json" || true
'
```

Per vedere i bundle conservati e controllare se il link `current` cambia nel
tempo:

```bash
lxc exec k3s-datacenter -- sh -ec '
  ls -lah /srv/terna-static-dr/static/current
  ls -ld /srv/terna-static-dr/static/bundles/bundle.* 2>/dev/null || true
  find /srv/terna-static-dr/static/bundles \
    -mindepth 1 -maxdepth 1 -type d -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" \
    | sort
'
```

### 1.2 Verificare il timer e forzare uno snapshot manuale

Il timer deve risultare abilitato e deve avere una prossima esecuzione:

```bash
lxc exec k3s-datacenter -- \
  systemctl status terna-static-origin-fetch.timer --no-pager -l
lxc exec k3s-datacenter -- \
  systemctl list-timers terna-static-origin-fetch.timer --all --no-pager
```

Per forzare subito una nuova acquisizione:

```bash
lxc exec k3s-datacenter -- \
  systemctl reset-failed terna-static-origin-fetch.service
lxc exec k3s-datacenter -- \
  systemctl start terna-static-origin-fetch.service
```

Essendo un servizio `oneshot`, dopo il successo può risultare `inactive`; lo
stato affidabile è `Result=success` con `ExecMainStatus=0`:

```bash
lxc exec k3s-datacenter -- \
  systemctl show terna-static-origin-fetch.service \
  -p Result -p ExecMainStatus -p ActiveEnterTimestamp

lxc exec k3s-datacenter -- \
  journalctl -u terna-static-origin-fetch.service -n 100 --no-pager -l
```

Se l'API del grafico risponde `401`, il servizio deve comunque terminare con
successo. Nei log è atteso un messaggio simile a:

```text
Terna load chart degraded: auth_failed; placeholder published.
Terna static bundle refreshed (...)
```

Il `401` degrada soltanto il grafico. Errori della homepage, della validazione
del bundle o della scrittura locale restano invece bloccanti. Durante un DR già
attivo il timer salta intenzionalmente l'acquisizione e scrive
`Terna DR is active; scheduled snapshot refresh skipped.`.

### 1.3 Diagnosticare un'acquisizione fallita

```bash
lxc exec k3s-datacenter -- \
  systemctl status terna-static-origin-fetch.service --no-pager -l
lxc exec k3s-datacenter -- \
  journalctl -xeu terna-static-origin-fetch.service --no-pager -l

lxc exec k3s-datacenter -- sh -ec '
  test -d /run/terna-static-dr
  ls -ld /run/terna-static-dr
  test -e /run/terna-static-dr/origin-fetch.lock
'

lxc exec k3s-datacenter -- sh -ec '
  current=/srv/terna-static-dr/static/current
  readlink -f "$current"
  test -s "$current/index.html"
  test -s "$current/manifest.json"
  test -f "$current/.bundle-v1"
  test -s "$current/dr/load-chart/index.html"
  test -s "$current/dr/load-chart/data.json"
'
```

Se compare ancora `Terna load chart failed: ... 401 ...` seguito da exit code
`1`, è installato il vecchio builder: aggiornare il repository e rilanciare
`reconcile-lxc-lab.sh`. Se compare `Read-only file system` su `/run/lock`, è
installato il vecchio fetcher o la vecchia unit systemd: il controllo con
`systemctl cat` della sezione 1 deve mostrare la runtime directory dedicata.

## 2. Verificare il primario pubblico

Prima del failover `server-dns` non deve essere autorevole per `terna.it`:

```bash
dig @10.10.2.53 terna.it A +short
dig @10.10.2.53 www.terna.it A +short
```

`www.terna.it` deve restituire un indirizzo IPv4 pubblico, non `10.10.3.10`.
L'apex `terna.it` può anche non avere un record A pubblico: ciò che conta è
che non restituisca l'IP del DR finché la zona locale non esiste.

Il controller sonda il primario attraverso il resolver WAN di `router-edge`,
così non viene ingannato dalla futura zona DNS locale. Verificarlo una volta
manualmente:

```bash
lxc exec router-edge -- ifstatus wan
lxc exec ansible-node -- sh -lc '
  public_ip=$(dig @10.10.4.2 +short www.terna.it A | head -n 1)
  test -n "$public_ip"
  curl --fail --silent --show-error \
    --resolve "www.terna.it:443:${public_ip}" \
    https://www.terna.it/
'
```

### 2.1 Verificare il percorso DNS completo

Questi test distinguono problemi di `router-edge`, ricorsione Bind, CoreDNS e
resolver WSL. Eseguirli nell'ordine indicato:

```bash
# Resolver WAN esposto da router-edge sul transito.
lxc exec router-dmz -- nslookup registry-1.docker.io 10.10.4.2
lxc exec router-edge -- ip route get 10.10.3.10

# Raggiungibilità e query DNS dal nodo K3s.
lxc exec k3s-datacenter -- ping -c 1 -W 2 10.10.4.2
lxc exec k3s-datacenter -- \
  dig @10.10.4.2 +time=2 +tries=1 registry-1.docker.io A
lxc exec k3s-datacenter -- \
  dig @10.10.4.2 +tcp +time=2 +tries=1 registry-1.docker.io A

# Ricorsione attraverso il DNS primario del lab.
lxc exec k3s-datacenter -- \
  dig @10.10.2.53 +time=4 +tries=1 registry-1.docker.io A
lxc exec server-dns -- \
  dig @10.10.4.2 +time=4 +tries=1 www.terna.it A
```

Per verificare la risoluzione usata dai pod:

```bash
lxc exec k3s-datacenter -- kubectl -n kube-system get pods -l k8s-app=kube-dns
lxc exec k3s-datacenter -- kubectl -n kube-system logs deployment/coredns --tail=100
lxc exec k3s-datacenter -- cat /etc/rancher/k3s/resolv.conf
```

Interpretazione rapida:

- se fallisce già la query da `router-dmz`, controllare dnsmasq/firewall di
  `router-edge`;
- se `10.10.4.2` funziona da K3s ma `10.10.2.53` no, controllare Bind e i
  forwarder su `server-dns`;
- se le query dal nodo funzionano ma falliscono dai pod, controllare CoreDNS e
  `/etc/rancher/k3s/resolv.conf`;
- un `traceroute www.terna.it` mostra la destinazione scelta, non quale server
  DNS ha risposto: per provare il resolver usare sempre `dig` o `resolvectl`.

## 3. Aprire il primario con Firefox in WSL

Per usare `server-dns` anche nell'host WSL, `/etc/wsl.conf` deve contenere
queste sezioni (preservare eventuali sezioni esistenti):

```ini
[boot]
systemd=true

[network]
generateResolvConf=false
```

Dopo la prima modifica, eseguire `wsl --shutdown` da PowerShell, riaprire WSL
e abilitare il resolver del lab:

```bash
cd "$REPO_ROOT/automazione/lxc-lab"
sudo bash host-dns.sh enable
resolvectl flush-caches
sudo bash host-dns.sh status
readlink -f /etc/resolv.conf
resolvectl status
resolvectl query www.terna.it
dig @10.10.2.53 server-dns.lab.lxc A +short
getent ahostsv4 www.terna.it
```

Prima del DR, `resolvectl` deve mostrare un IP pubblico. Aprire il sito
pubblico:

```bash
firefox --private-window 'https://www.terna.it/it'
```

Firefox deve usare il resolver di sistema. Disabilitare temporaneamente DNS
over HTTPS nelle impostazioni del browser durante il drill; in caso contrario
Firefox può continuare a interrogare un resolver pubblico anche se WSL usa
correttamente `server-dns`.

## 4. Installare e armare il controller

Creare la configurazione locale, senza sovrascriverla se esiste già:

```bash
cd "$REPO_ROOT/automazione/terna-static-dr"
test -f config.lxc-lab.env || cp config.lxc-lab.env.example config.lxc-lab.env
```

Aprire `config.lxc-lab.env` e lasciare inizialmente il controller disarmato:

```ini
TERNA_DR_AUTO_FAILOVER_ENABLED=false
TERNA_CONTROLLER_FAILURE_THRESHOLD=3
TERNA_CONTROLLER_INTERVAL_SECONDS=120
TERNA_PRIMARY_PROBE_URL=https://www.terna.it/
TERNA_PUBLIC_DNS_RESOLVER=10.10.4.2
TERNA_STATIC_HEALTH_URL=http://terna.it/health
```

Installare il controller, che rimarrà disabilitato. È preferibile usare il
reconcile perché verifica anche il proxy del socket LXD su `ansible-node`:

```bash
bash bin/reconcile-lxc-lab.sh
```

Dopo le verifiche delle sezioni 1 e 2, modificare nello stesso file:

```ini
TERNA_DR_AUTO_FAILOVER_ENABLED=true
```

Riconciliare nuovamente per distribuire la configurazione e armare il servizio:

```bash
bash bin/reconcile-lxc-lab.sh
lxc exec ansible-node -- systemctl status terna-static-dr-controller --no-pager
lxc exec ansible-node -- env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env \
  bash /opt/terna-static-dr/bin/lxc-lab-controller.sh validate
```

Controllare che configurazione, socket LXD e URL di health check siano quelli
attesi:

```bash
lxc exec ansible-node -- \
  grep -E '^(TERNA_DR_AUTO_FAILOVER_ENABLED|TERNA_PRIMARY_PROBE_URL|TERNA_PUBLIC_DNS_RESOLVER|TERNA_STATIC_HEALTH_URL)=' \
  /etc/terna-static-dr/config.env

lxc exec ansible-node -- test -S /var/snap/lxd/common/lxd/unix.socket
lxc exec ansible-node -- /usr/local/bin/lxc list --format=compact
```

Gli URL si configurano in `config.lxc-lab.env`:

```ini
TERNA_PRIMARY_PROBE_URL=https://www.terna.it/
TERNA_STATIC_HEALTH_URL=http://terna.it/health
```

Il primo deve rimanere HTTPS sul sito pubblico `www.terna.it`; il secondo deve
essere un endpoint HTTP locale su `terna.it` o `www.terna.it`. Dopo ogni
modifica rilanciare `bash bin/reconcile-lxc-lab.sh`.

Aprire un terminale dedicato per osservare il controller:

```bash
lxc exec ansible-node -- journalctl -u terna-static-dr-controller -f
```

Prima del drill il log deve mostrare un messaggio analogo a:

```text
public Terna primary ready; lab DNS remains primary (cutback is manual)
```

## 5. Simulare il guasto WAN e attivare il DR

Con il log già aperto, interrompere esclusivamente la WAN del laboratorio:

```bash
lxc exec router-edge -- ifdown wan
```

Con i valori predefiniti, il controller rileva 3 errori a intervalli di 120
secondi: il failover può richiedere fino a circa 6 minuti. Il log deve indicare
la progressione delle indisponibilità e poi la pubblicazione della zona locale.

In un secondo terminale si possono seguire contemporaneamente controller e
DNS:

```bash
lxc exec ansible-node -- \
  journalctl -u terna-static-dr-controller -f -n 50
```

Per un drill più rapido e deterministico, fermare temporaneamente il loop e
invocare `oneshot` per il numero configurato di errori. Non eseguire questa
variante mentre il servizio automatico è ancora attivo:

```bash
lxc exec ansible-node -- systemctl stop terna-static-dr-controller.service

for attempt in 1 2 3; do
  echo "=== probe $attempt ==="
  lxc exec ansible-node -- \
    env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env \
    bash /opt/terna-static-dr/bin/lxc-lab-controller.sh oneshot
done

lxc exec ansible-node -- systemctl start terna-static-dr-controller.service
```

Non spegnere `server-dns`, `k3s-datacenter` o `ansible-node`: il drill simula
la perdita del primario/WAN, non del datacenter di recovery.

## 6. Verificare il DR completato

Controllare stato controller, zona DNS e pod:

```bash
lxc exec ansible-node -- cat /var/lib/terna-static-dr/mode
lxc exec ansible-node -- cat /var/lib/terna-static-dr/failures
dig @10.10.2.53 terna.it A +short
dig @10.10.2.53 www.terna.it A +short
lxc exec k3s-datacenter -- kubectl -n terna-static-dr get deployment,pods
lxc exec k3s-datacenter -- test -f /srv/terna-static-dr/static/dr-active
lxc exec server-dns -- named-checkconf
lxc exec server-dns -- cat /etc/bind/zones/db.terna.it
```

Risultati attesi:

- `mode` è `dr`;
- entrambe le query DNS restituiscono `10.10.3.10`;
- il deployment `terna-static-web` è pronto;
- esiste il file `/srv/terna-static-dr/static/dr-active` sul nodo
  `k3s-datacenter`.

Verificare endpoint, contenuto statico e grafico locale:

```bash
curl --fail --silent --show-error -H 'Host: terna.it' \
  http://10.10.3.10/health
curl --fail --silent --show-error -H 'Host: www.terna.it' \
  http://10.10.3.10/it >/dev/null
curl --fail --silent --show-error -H 'Host: terna.it' \
  http://10.10.3.10/dr/load-chart/index.html >/dev/null
lxc exec k3s-datacenter -- test -f /srv/terna-static-dr/static/dr-active
```

Per verificare che la pagina ricevuta sia davvero quella del bundle statico e
non il sito pubblico:

```bash
curl --fail --silent --show-error \
  -H 'Host: www.terna.it' http://10.10.3.10/it \
  | head -n 20

curl --fail --silent --show-error \
  -H 'Host: www.terna.it' http://10.10.3.10/it \
  | wc -c
```

### Verifica con Firefox in WSL

L'host WSL deve già usare `server-dns` dalla sezione 3. Svuotare la cache DNS
e confermare lo switch:

```bash
resolvectl flush-caches
resolvectl query terna.it
resolvectl query www.terna.it
dig terna.it A +short
dig www.terna.it A +short
getent ahostsv4 www.terna.it
curl --fail --silent --show-error http://www.terna.it/health
curl --fail --silent --show-error http://www.terna.it/it >/dev/null
```

Entrambe le risoluzioni devono riportare `10.10.3.10`. Aprire il fallback con
**HTTP**, non HTTPS: la PoC non possiede il certificato pubblico di Terna per
terminare TLS nel lab.

```bash
firefox --private-window 'http://www.terna.it/it'
```

Verificare nel browser che la homepage sia visibile e che il grafico locale del
fabbisogno totale Italia sia presente. Non aspettarsi dati realtime, login o
form funzionanti: sono fuori dallo scope della copia statica.

## 7. Ripristinare il primario e fare il cutback DNS

Riportare in servizio la WAN simulata:

```bash
lxc exec router-edge -- ifup wan
lxc exec router-edge -- ifstatus wan
```

Verificare che il controller riesca nuovamente a raggiungere il primario. Il
controller non fa il cutback da solo e mantiene il DNS sul DR finché non viene
comandato esplicitamente:

```bash
lxc exec ansible-node -- env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env \
  bash /opt/terna-static-dr/bin/lxc-lab-controller.sh oneshot
```

L'output atteso contiene `public Terna primary ready; lab DNS remains dr
(cutback is manual)`.

Eseguire quindi il cutback. Questo rimuove la zona Bind locale `terna.it`,
rimuove `dr-active` e riporta lo stato a `primary`:

```bash
lxc exec ansible-node -- test -S /var/snap/lxd/common/lxd/unix.socket
lxc exec ansible-node -- /usr/local/bin/lxc list --format=compact

lxc exec ansible-node -- env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env \
  bash /opt/terna-static-dr/bin/lxc-lab-controller.sh delete-lab-zone
```

Se il controllo del socket restituisce `lxd-user/unix.socket: connection
refused`, non forzare modifiche manuali a Bind: dall'host WSL rilanciare
`bash automazione/terna-static-dr/bin/reconcile-lxc-lab.sh`, che ripara il
proxy del socket LXD, quindi ripetere il cutback.

Verificare il ritorno al sito pubblico:

```bash
dig @10.10.2.53 terna.it A +short
dig @10.10.2.53 www.terna.it A +short
lxc exec ansible-node -- cat /var/lib/terna-static-dr/mode
lxc exec k3s-datacenter -- sh -ec \
  'test ! -e /srv/terna-static-dr/static/dr-active'
lxc exec server-dns -- sh -ec \
  'test ! -e /etc/bind/zones/db.terna.it'
lxc exec server-dns -- named-checkconf
```

`www.terna.it` deve tornare a un IP pubblico; `terna.it` può essere privo di A
ma non deve più restituire `10.10.3.10`. Lo stato deve essere `primary` e il
marker `dr-active` non deve più esistere. Per la verifica finale su Firefox:

```bash
resolvectl flush-caches
firefox --private-window 'https://www.terna.it/it'
```

## 8. Ripristinare il DNS normale di WSL (opzionale)

Quando si termina il test, togliere il resolver del lab dall'host WSL:

```bash
cd "$REPO_ROOT/automazione/lxc-lab"
sudo bash host-dns.sh disable
```

## 9. Diagnostica rapida

### 9.1 Kubernetes, Nginx e Ingress

```bash
lxc exec k3s-datacenter -- kubectl -n terna-static-dr get all -o wide
lxc exec k3s-datacenter -- kubectl -n terna-static-dr get ingress,service -o wide
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  rollout status deployment/terna-static-web --timeout=120s
lxc exec k3s-datacenter -- kubectl -n terna-static-dr describe pods
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  get events --sort-by=.lastTimestamp
lxc exec k3s-datacenter -- kubectl -n terna-static-dr get pods -w
```

L'ultimo comando resta in ascolto; terminarlo con `Ctrl+C` dopo che il pod è
`Running` e `Ready`.

Per leggere i log del pod corrente senza copiarne manualmente il nome:

```bash
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  logs deployment/terna-static-web -c static-web --tail=200
```

Se il container è in `CrashLoopBackOff`, leggere anche il tentativo precedente:

```bash
pod=$(lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  get pod -l app=terna-static-web \
  -o jsonpath='{.items[0].metadata.name}')

lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  logs "$pod" -c static-web --previous --tail=200
```

Verificare file e permessi visti direttamente da Nginx:

```bash
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  exec deployment/terna-static-web -c static-web -- sh -ec '
    id
    ls -ld /usr/share/nginx/html/current
    test -r /usr/share/nginx/html/current/index.html
    test -r /usr/share/nginx/html/current/manifest.json
    test -r /usr/share/nginx/html/current/dr/load-chart/index.html
  '
```

Testare l'Ingress senza dipendere dal DNS:

```bash
curl -v --resolve terna.it:80:10.10.3.10 \
  http://terna.it/health
curl -v --resolve www.terna.it:80:10.10.3.10 \
  http://www.terna.it/it -o /tmp/terna-static.html
wc -c /tmp/terna-static.html
```

Un `403` Nginx richiede di verificare che `current` punti a un bundle esistente
e che tutte le directory del percorso siano attraversabili dal gruppo `101`:

```bash
lxc exec k3s-datacenter -- sh -ec '
  namei -l /srv/terna-static-dr/static/current/index.html
  readlink -f /srv/terna-static-dr/static/current
  stat -c "%A %u:%g %n" \
    /srv/terna-static-dr/static \
    /srv/terna-static-dr/static/current \
    /srv/terna-static-dr/static/current/index.html
'
```

### 9.2 DNS del lab e DNS dell'host WSL

```bash
# Query diretta: prova server-dns indipendentemente dalla configurazione WSL.
dig @10.10.2.53 terna.it A +short
dig @10.10.2.53 www.terna.it A +short

# Query applicativa: prova ciò che useranno curl e Firefox in WSL.
sudo bash "$REPO_ROOT/automazione/lxc-lab/host-dns.sh" status
readlink -f /etc/resolv.conf
resolvectl status
resolvectl query www.terna.it
getent ahostsv4 www.terna.it

# Stato Bind e zona locale eventuale.
lxc exec server-dns -- systemctl status named --no-pager -l
lxc exec server-dns -- named-checkconf
lxc exec server-dns -- sh -ec \
  "grep -n -A5 -B1 'zone \"terna.it\"' /etc/bind/named.conf.local || true"
```

Interpretazione:

- `dig @10.10.2.53` corretto ma `getent` errato: WSL non sta usando
  `server-dns`, oppure la cache non è stata svuotata;
- `curl` corretto ma Firefox errato: controllare cache e DNS over HTTPS del
  browser;
- in `primary` non deve esserci una zona locale `terna.it` e la risposta deve
  essere pubblica;
- in `dr` la zona deve esistere e rispondere `10.10.3.10` per apex e `www`.

### 9.3 Connettività Internet e immagini K3s

```bash
lxc exec k3s-datacenter -- dig +short A registry-1.docker.io
lxc exec k3s-datacenter -- \
  curl -4 --http1.1 -vk --connect-timeout 10 --max-time 30 \
  https://registry-1.docker.io/v2/
lxc exec k3s-datacenter -- systemctl show k3s -p Environment --value
lxc exec k3s-datacenter -- systemctl cat k3s
lxc exec k3s-datacenter -- k3s ctr -n k8s.io images list \
  | grep 'nginx.*1.27-alpine'
```

Una risposta HTTP `401 Unauthorized` da `/v2/` è normale e dimostra che DNS,
TCP e TLS verso Docker Hub funzionano. Un timeout DNS/TLS indica invece un
problema di rete del nodo. Se il registry non è raggiungibile dal nodo ma
l'immagine esiste già nel Docker dell'host, precaricarla manualmente:

```bash
docker pull nginx:1.27-alpine
docker save nginx:1.27-alpine \
  | lxc exec k3s-datacenter -- k3s ctr -n k8s.io images import -
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  rollout restart deployment/terna-static-web
lxc exec k3s-datacenter -- kubectl -n terna-static-dr \
  rollout status deployment/terna-static-web --timeout=180s
```

### 9.4 Controller

```bash
lxc exec ansible-node -- \
  systemctl status terna-static-dr-controller.service --no-pager -l
lxc exec ansible-node -- \
  journalctl -u terna-static-dr-controller.service -n 120 --no-pager -l
lxc exec ansible-node -- cat /var/lib/terna-static-dr/mode
lxc exec ansible-node -- cat /var/lib/terna-static-dr/failures
lxc exec ansible-node -- \
  env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env \
  bash /opt/terna-static-dr/bin/lxc-lab-controller.sh validate
```

## 10. Test locali del progetto (opzionale)

Questi test non avviano il drill, ma controllano contratti, controller e
costruzione del bundle:

```bash
cd "$REPO_ROOT"
bash automazione/terna-static-dr/tests/lxc_lab_contract_test.sh
bash automazione/terna-static-dr/tests/lxc_lab_controller_behavior_test.sh
python3 automazione/terna-static-dr/tests/static_bundle_builder_test.py
```

La stessa suite Python può essere eseguita in un unico comando:

```bash
python3 -m unittest discover \
  -s automazione/terna-static-dr/tests -p '*_test.py'
```

Verificare anche i contratti dello setup LXC e la sintassi Bash:

```bash
bash automazione/lxc-lab/tests/terna_static_dr_setup_contract_test.sh
bash automazione/lxc-lab/tests/host_dns_contract_test.sh
bash automazione/lxc-lab/tests/instance_running_test.sh

bash -n \
  automazione/terna-static-dr/host-fetch/terna-static-origin-fetch.sh \
  automazione/terna-static-dr/bin/lxc-lab-controller.sh \
  automazione/terna-static-dr/bin/reconcile-lxc-lab.sh
```

## 11. Checklist di accettazione

Il drill è riuscito soltanto se tutti i punti seguenti sono veri:

- in `primary`, WSL interroga `server-dns` ma `www.terna.it` risolve a un IP
  pubblico;
- il timer è abilitato e uno snapshot manuale termina con
  `Result=success`/`ExecMainStatus=0`;
- `current` punta a un bundle con HTML, manifest, `.bundle-v1` e componente
  grafico locale;
- dati API validi producono `.load-chart-v1`; errori API o credenziali assenti
  producono `.load-chart-placeholder-v1` senza bloccare lo snapshot;
- il Deployment `terna-static-web` è `Available` nel namespace
  `terna-static-dr` e `/health` risponde `200`;
- dopo il guasto WAN il controller passa a `dr`, crea `dr-active` e
  `server-dns` restituisce `10.10.3.10` per `terna.it` e `www.terna.it`;
- da WSL `http://www.terna.it/it` mostra il bundle statico usando il DNS del
  lab;
- dopo `ifup wan` e `delete-lab-zone`, lo stato torna `primary`, `dr-active` e
  la zona locale scompaiono, e WSL torna al sito pubblico HTTPS.
