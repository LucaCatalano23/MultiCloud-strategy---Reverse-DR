# provision-cli — provisioning del primario AWS via AWS CLI

`provision.sh` è la traduzione eseguibile di
[`RUNBOOK_PROVISIONING_AWS.md`](../../../RUNBOOK_PROVISIONING_AWS.md): stessa
architettura, stesse scelte deliberate, ma con comandi AWS CLI al posto della
console. **Nessun Terraform.**

Non sostituisce Terraform: non ha uno state authoritative né un piano di diff. È
uno script di bootstrap ri-eseguibile — gli ID creati finiscono in
`~/.reverse-dr/state.env`, ricaricato a ogni sezione, e ogni risorsa foundational
è creata solo se assente. Puoi eseguire una sezione alla volta e riprendere dopo
un errore.

## Prerequisiti

- WSL con `aws` v2, `jq`, `kubectl`, `helm`, `docker`, `git`, `openssl`;
- credenziali AWS attive (`aws sts get-caller-identity` risponde);
- `eu-south-1` abilitata (lo verifica `preflight`);
- per il login: la chiave privata e il certificato del BFF in PEM (§2.1 del
  runbook), consegnati dal team identità.

## Input da impostare prima di partire

Lo script non inventa i valori esterni: esportali, oppure modifica la testa del
file. Le sezioni che li richiedono si fermano con un messaggio esplicito se
mancano.

```bash
export REPO_ROOT=/path/to/repository
export APP_HOST=heliospoc.ggg.it

# Valori dal team identità (application demo-api-app/demo-bff-app).
# Il tenant non è una variabile a sé: è già dentro le URL qui sotto.
export ENTRA_API_CLIENT_ID=...          # GUID, non api://...
export ENTRA_BFF_CLIENT_ID=...
export ENTRA_ISSUER_URL=https://login.microsoftonline.com/<tenant>/v2.0
export ENTRA_JWKS_URL=...
export ENTRA_AUTHORIZATION_ENDPOINT=...
export ENTRA_TOKEN_ENDPOINT=...
export ENTRA_END_SESSION_ENDPOINT=...
export ENTRA_API_SCOPE=api://<api-client-id>/access_as_user

# Credenziale confidenziale del BFF (private_key_jwt). Due modi, uno solo serve.
#
# a) Hai un .pfx (PKCS#12, il formato tipico di Windows): passalo così com'è.
#    s12 estrae chiave e certificato da solo, chiede la password in modo
#    interattivo e distrugge i PEM temporanei a fine sezione.
export BFF_PFX=/mnt/c/Users/user/Desktop/cloud-app-dev-heliosbff-tlabpal.pfx
#
# b) Hai già i due PEM separati (default /tmp/bff-key.pem, /tmp/bff-cert.pem):
# export BFF_KEY_PEM=/percorso/bff-key.pem
# export BFF_CERT_PEM=/percorso/bff-cert.pem
```

Opzionali con default sensati: `AWS_REGION` (`eu-south-1`), `PREFIX`
(`reverse-dr-poc`), `EKS_ADMIN_ROLE_ARN` (auto-rilevato per un ruolo SSO AdministratorAccess),
`IMAGE_TAG` (default: short SHA di git, o un timestamp se la copia non è un
checkout git — consigliato impostarlo, es. `poc-1`).

### Hostname interno o placeholder: certificato self-signed

La CA pubblica di ACM **non emette** per domini non pubblici (`*.azienda.lan`,
nomi d'esempio): il certificato va in `FAILED`. Se `APP_HOST` è interno, imposta:

```bash
export ACM_SELF_SIGNED=1
```

`s03_acm` genera allora un certificato self-signed per `APP_HOST` e lo importa in
ACM. Il browser mostra un avviso da accettare una volta, ma TLS sull'ALB, login
OIDC e cookie `__Host-*` funzionano — è un limite PoC dichiarato. Per raggiungere
l'app dal browser, fai puntare `APP_HOST` all'hostname dell'ALB via DNS interno o
`/etc/hosts` (l'hostname ALB lo stampa `verify`).

## Uso

```bash
chmod +x provision.sh
./provision.sh preflight     # regione opt-in, disponibilità servizi, scelta AZ
./provision.sh all           # tutte le sezioni in ordine
```

Oppure una sezione per volta, nell'ordine di `all()`:

```bash
./provision.sh s04_network
./provision.sh s06_eks
# ...
./provision.sh verify
```

### Ripresa dopo un errore del node group

`s15_platform` installa componenti Kubernetes, ma non crea i worker: il managed
node group appartiene a `s06_eks`. Prima dei comandi Helm, `s15_platform`
verifica quindi che esista almeno un nodo `Ready` e si ferma con una diagnostica
esplicita se il requisito non e' soddisfatto.

Per riprendere dopo un errore di join dei nodi:

```bash
./provision.sh s04_network  # riconcilia NAT, route e associazioni delle subnet
./provision.sh s06_eks      # riprende CREATING o ricrea un CREATE_FAILED
./provision.sh s15_platform
```

La riesecuzione e' convergente: un node group `ACTIVE` non viene toccato; uno in
`CREATING` viene atteso; uno in `CREATE_FAILED` viene diagnosticato, eliminato e
ricreato una sola volta. Uno stato `DEGRADED` non viene invece cancellato in
automatico, per non interrompere eventuali workload gia' in esecuzione.

Teardown guidato (richiede di digitare `distruggi`):

```bash
./provision.sh teardown
```

## Passi che restano manuali — per scelta

Tre punti non sono automatizzabili da qui perché dipendono da sistemi esterni; lo
script si ferma e lo dice:

- **Validazione DNS del certificato ACM** (`s03_acm`): stampa il record CNAME da
  creare nella tua zona, poi attende lo stato `ISSUED`.
- **Record DNS finale** verso l'hostname dell'ALB (`verify`): l'ALB nasce solo
  dopo l'apply dell'Ingress.
- **PEM del certificato BFF** (`s12_bootstrap`): sono la credenziale che il team
  identità emette, non questo account.

## CloudWatch non utilizzato

Il provisioning non crea log group, mantiene disabilitati tutti i log del
control plane EKS e non abilita gli export RDS. Il ruolo Lambda non riceve
permessi di scrittura sui log; rieseguendo lo script, l'eventuale policy
`AWSLambdaBasicExecutionRole` applicata da versioni precedenti viene rimossa.

Le metriche RPO/RTO applicative restano nella tabella `dr_telemetry` di
PostgreSQL. Le metriche di servizio pubblicate automaticamente da AWS possono
comparire nella Console, ma non sono risorse configurate da questo script.

I log group creati da esecuzioni precedenti non vengono cancellati
automaticamente, perché contengono dati storici. Dopo averne verificato il
contenuto possono essere eliminati esplicitamente:

```bash
aws logs delete-log-group --log-group-name "/aws/eks/${PREFIX:-reverse-dr-poc}/cluster"
aws logs delete-log-group --log-group-name "/aws/lambda/${PREFIX:-reverse-dr-poc}-ticket-automation"
```

La cancellazione è definitiva; un errore `ResourceNotFoundException` indica che
il gruppo era già assente.

## Fedeltà all'architettura

Lo script rispetta le decisioni dichiarate (CLAUDE.md §3): single-AZ applicativo,
NAT instance invece di NAT Gateway, subnet witness senza workload, RDS non
multi-AZ, node group su una sola subnet. `verify` include i controlli che lo
confermano sull'infrastruttura reale — necessari perché, senza Terraform, i test
statici del repository descrivono il codice, non ciò che è stato creato a mano.
