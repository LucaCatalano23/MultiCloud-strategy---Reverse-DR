# OpenBao — vault manager del sito DR

I segreti applicativi hanno lo stesso trattamento dell'identità e
dell'automazione: **stesso contratto, provider diverso per sito**.

| | Sito primario | Sito DR |
| --- | --- | --- |
| Backend | AWS Secrets Manager | OpenBao su nodo `vault-openbao` |
| Autenticazione | IRSA (ruolo per workload) | ServiceAccount Kubernetes (ruolo per namespace) |
| Consumo | External Secrets Operator | External Secrets Operator |
| Manifest | `infra/aws/kubernetes/external-secrets.yaml` | `infra/onprem/secrets/external-secrets.yaml` |

Il punto architetturale: **i Deployment non cambiano di una riga fra i due
siti**. Continuano a montare `helios-app-database`, `helios-bff-runtime`,
`keycloak-postgres` e gli altri come normali Secret Kubernetes. Cambia solo chi
li produce. Nessun workload sa da quale vault provengono le proprie credenziali,
esattamente come nessun workload sa se il token che valida viene da Entra o da
Keycloak.

## Perché un nodo dedicato e non un workload k3s

Il vault custodisce le credenziali del cluster: farlo girare *dentro* il
cluster che protegge significa che un rebuild di `k3s-datacenter` porta via il
materiale crittografico, e che il perimetro di fiducia coincide con ciò che
dovrebbe essere protetto. `vault-openbao` (10.10.3.80) vive in
`lab-datacenter` accanto a `git-server` e `ansible-node`, ed è configurato con
`boot.autostart=true` come il coordinatore DR: deve tornare su da solo dopo un
riavvio di LXD o WSL.

## Il sigillo: la decisione che regge il DR

OpenBao parte sempre **sigillato**. Le tre strade possibili:

| Strategia | Perché sì | Perché no |
| --- | --- | --- |
| **Shamir** (meccanismo di sigillo scelto) | Nessuna dipendenza esterna: funziona anche a cloud irraggiungibile | Da solo, dopo un riavvio del nodo serve un operatore |
| Auto-unseal via KMS AWS | Standard in produzione, nessun intervento umano | Dipende dal sito primario **proprio quando il primario è caduto**: contraddice la premessa del reverse DR |
| **Chiavi su disco + systemd** (attivato su richiesta, opt-in) | Riavvio non presidiato: il sito DR resta sempre operativo | Chiave e lucchetto sullo stesso disco: vedi "Il compromesso" più sotto |

La PoC usa **Shamir**, e la conseguenza è dichiarata: OpenBao è tenuto *warm e
già dissigillato*, come Keycloak, perché il failover non può spostare il DNS
prima che i segreti siano leggibili. `verify-openbao.sh` è il preflight che il
playbook esegue **prima** di scalare i workload e di toccare il DNS: se il vault
è sigillato o irraggiungibile il failover fallisce e il rescue riporta i
Deployment a zero repliche, invece di promuovere un sito i cui pod resterebbero
in `CreateContainerConfigError`.

## Auto-unseal

Il sigillo Shamir da solo lascia OpenBao sigillato dopo un riavvio del nodo: il
container torna su da solo, il servizio no. Poiché il requisito operativo di
questa PoC è che **Keycloak e OpenBao siano sempre operativi**, è disponibile un
auto-unseal locale:

```bash
export OPENBAO_UNSEAL_KEYS="<share1> <share2> <share3>"
```

```bash
export OPENBAO_ACCEPT_AUTO_UNSEAL_RISK=yes
```

```bash
bash automazione/infra/vault/scripts/enable-auto-unseal.sh
```

Installa un runner e una unit systemd `openbao-auto-unseal.service` che, dopo
`openbao.service`, attende il listener e dissigilla leggendo le chiavi da
`/etc/openbao/unseal/keys` (root, `0400`). Il runner è idempotente: su un vault
già dissigillato non fa nulla, e le chiavi passano da stdin, non da `argv`,
perché la process list del nodo è leggibile da qualunque utente locale.

### Il compromesso, senza giri di parole

Le chiavi Shamir finiscono **sullo stesso filesystem** che ospita lo storage
cifrato. Chi ottiene il disco del nodo ottiene lucchetto e chiave insieme:
il sigillo smette di proteggere da un furto del volume e protegge solo da un
accesso applicativo non privilegiato. Resta comunque preferibile a Secret
Kubernetes in chiaro in etcd, perché l'accesso ai segreti continua a passare da
policy, autenticazione e audit log di OpenBao — ma non va raccontato come se il
vault fosse ancora sigillato in senso pieno.

Per questo l'attivazione è **opt-in esplicito e mai un default**:
`install-openbao.sh` non lo invoca, lo script pretende
`OPENBAO_ACCEPT_AUTO_UNSEAL_RISK=yes`, e
`automazione/tests/deployment-contract.ps1` fallisce se l'installazione
dovesse abilitarlo implicitamente.

In produzione la strada corretta è un auto-unseal la cui autorità di sigillo
risieda **nel sito DR** e non sullo stesso nodo: un HSM locale, oppure un
secondo OpenBao in transit unseal. Nessuna delle due è replicabile in un
container LXC, per questo il lab si ferma qui.

Conserva comunque una copia delle chiavi **fuori dal laboratorio**: se il nodo
si perde, senza di esse lo storage è irrecuperabile.

## Layout dei segreti

Mount KV v2 `helios/`:

```text
helios/onprem/application/database          DATABASE_URL
helios/onprem/application/bff-runtime       OIDC_CLIENT_SECRET, SESSION_ENCRYPTION_KEY
helios/onprem/application/tls               tls.crt, tls.key
helios/onprem/identity/keycloak-postgres    POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
helios/onprem/identity/keycloak-bootstrap-admin  username, password
helios/onprem/identity/bff-oidc             OIDC_CLIENT_SECRET
helios/onprem/identity/dr-operator          username, password, employee_id, email
helios/onprem/identity/tls                  tls.crt, tls.key
```

Due policy in sola lettura, una per namespace (`helios-desk-read`,
`helios-identity-read`). Nessuna concede scrittura: chi consuma i segreti non
deve poterli modificare, e la rotazione passa da `seed-secrets.sh` con un token
amministrativo che non risiede nel cluster.

La granularità è **per namespace**, non per workload come su AWS. È una
differenza reale e voluta: su AWS è IRSA a legare il permesso al singolo pod,
mentre qui il fetch lo esegue il controller ESO, non il pod. Dichiarare una
granularità per workload darebbe l'illusione di un isolamento che il controller
non ha.

## Provisioning

```bash
export OPENBAO_VERSION=<versione verificata su github.com/openbao/openbao/releases>
```

```bash
bash automazione/infra/vault/scripts/install-openbao.sh
```

Poi, **una sola volta**, l'inizializzazione sul nodo. Non è in uno script di
proposito: produce le chiavi Shamir e il token di root, materiale che non deve
finire nell'output di un'automazione non presidiata.

```bash
lxc exec vault-openbao -- bao operator init
```

Conserva le chiavi fuori dal repository e fuori dal lab, poi dissigilla e
configura:

```bash
bash automazione/infra/vault/scripts/configure-openbao.sh
```

Infine popola i segreti, con le stesse variabili d'ambiente di prima:

```bash
bash automazione/infra/vault/scripts/seed-secrets.sh
```

`seed-secrets.sh` non scrive nulla nel repository, valida i vincoli già noti
(lunghezze minime, chiave Fernet, rifiuto del database legacy `helpdesk`) e non
espone mai il token in `argv`: viaggia in un file di configurazione curl con
permessi 600, perché la process list è leggibile da altri utenti del nodo.

## Prerequisito nel cluster

External Secrets Operator deve essere installato su `k3s-datacenter` prima del
deploy dello standby; `deploy-onprem-standby.sh` verifica la presenza delle CRD
e il preflight del vault, e si ferma se mancano.

## Per la produzione

- storage `file` significa nessuna replica: passare a Raft integrato con almeno 3 nodi;
- `disable_mlock = true` è una concessione ai container LXC: riattivarlo;
- l'admin bootstrap di Keycloak e il token di root di OpenBao vanno revocati dopo aver creato identità permanenti a privilegio minimo;
- i certificati TLS del vault vanno ruotati e monitorati come quelli dell'ingress.
