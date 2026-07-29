# Runbook — provisioning del sito primario AWS

Questa guida porta il **sito primario** della PoC Reverse DR da un account AWS vuoto a
Helios Desk funzionante su EKS, con RDS, ECR, EventBridge/SQS, Lambda e il CronJob di
backup che alimenta la metrica RPO della dashboard.

È il complemento cloud di [`RUNBOOK_SCENARIO_REALE.md`](RUNBOOK_SCENARIO_REALE.md), che
copre il sito DR on-prem. I due runbook si incontrano in due punti soltanto: il bucket S3
dei backup (che il DR consuma per il restore) e il contratto di identità (audience Entra
condivisa con Keycloak).

**Regione della PoC: `eu-south-1` (Milano).** Vedi §1.4 — è una regione *opt-in*, va
abilitata prima di qualsiasi altra cosa.

**Shell: bash da WSL.** Ogni blocco di questa guida è eseguibile così com'è da una shell
WSL, senza traduzioni. Dove serve un tool Windows (PowerShell) è indicato esplicitamente
con la sintassi di interoperabilità WSL.

---

## 0. Cosa provisiona questa guida — e cosa no

**Dentro lo scope:**

| Piano | Componenti |
|---|---|
| Rete | VPC, subnet primarie + witness, IGW, NAT instance `t4g.nano`, route table |
| Compute | EKS + un managed node group nella sola AZ primaria |
| Dati | RDS PostgreSQL single-AZ, bucket S3 backup e frontend |
| Registry | 5 repository ECR immutabili |
| Eventi | EventBridge bus + archive, SQS + DLQ, Lambda container opzionale |
| Identità workload | ruoli IRSA per BFF, ticket, automation, backup, controller ALB |
| Applicazione | overlay Kustomize `helios-desk`, ALB Ingress, External Secrets, CronJob backup |

**Fuori scope per scelta dichiarata** (vedi [`infra/aws/README.md`](infra/aws/README.md)):

- **Route 53 e ACM**: il certificato e il record DNS sono ownership esterna. Vanno creati
  a mano (§8) e il loro ARN/hostname entra nell'Ingress come placeholder.
- **NAT Gateway, WAF, ElastiCache, ALB da Terraform**: assenti per costo fisso o perché
  creati dal controller ALB a partire dall'Ingress.
- **Valori dei segreti**: Terraform crea i *contenitori* Secrets Manager vuoti, mai i
  valori. Il bootstrap è §5.
- **Entra ID**: è uno stack Terraform separato (`infra/entra`), su un tenant Azure. Va
  applicato **prima** (§2), perché i suoi output riempiono il ConfigMap del cloud.

**Il gate di apply.** Il repository è dichiarato review-only ([`CLAUDE.md`](../CLAUDE.md)
§6): nessuno script qui dentro esegue `terraform apply`. Questa guida documenta la
procedura, ma ogni `apply` resta una decisione esplicita dell'operatore, presa dopo aver
letto il piano. Le sezioni che modificano risorse reali sono marcate **⚠️ APPLY**.

> **Convenzione:** dove compare `<qualcosa>` fra parentesi angolari è un segnaposto da
> sostituire **prima** di eseguire. In bash `<` è una redirezione: lasciarlo produce
> `No such file or directory`, non un errore comprensibile. In questa guida i segnaposto
> compaiono solo fuori dai blocchi eseguibili o dentro file di configurazione.

---

## 1. Prerequisiti

### 1.1 Toolchain WSL

Tutto gira dentro la distribuzione WSL, non da PowerShell:

```bash
sudo apt update
sudo apt install -y unzip curl git jq python3 openssl coreutils
```

| Tool | Versione | Perché | Installazione |
|---|---|---|---|
| Terraform | `>= 1.10` | lock file nativo del backend S3 (`use_lockfile`) | [repo HashiCorp APT](https://developer.hashicorp.com/terraform/install) |
| AWS CLI | v2 | `update-kubeconfig`, ECR login, Secrets Manager | installer ufficiale, non `apt install awscli` (è v1) |
| kubectl | compatibile con `kubernetes_version` | overlay applicativo | `curl -LO ...` da dl.k8s.io |
| helm | `>= 3.12` | External Secrets Operator, AWS Load Balancer Controller | script `get-helm-3` |
| Docker | recente | build delle 6 immagini | Docker Desktop con integrazione WSL **oppure** engine nativo in WSL |
| jq | qualsiasi | estrazione degli output Terraform nei comandi | `apt` |
| kubeconform | opzionale | validazione dell'overlay renderizzato | binario da GitHub |

Due dettagli specifici di WSL che fanno perdere tempo se scoperti dopo:

- **Docker**: se usi Docker Desktop, l'integrazione con la distribuzione va abilitata in
  *Settings → Resources → WSL Integration*. Senza, `docker` esiste ma non trova il daemon.
- **Login che aprono il browser** (`aws sso login`, `az login`): l'interoperabilità WSL
  apre il browser di Windows. Se non succede, forza il flusso a codice:
  `aws sso login --use-device-code` e `az login --use-device-code`.

Per gli script PowerShell del repository non serve installare `pwsh` in WSL: si chiama
direttamente l'eseguibile di Windows, che WSL espone nel `PATH`.

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/static_contract.ps1
```

Funziona finché il repository è sotto `/mnt/c/...`, perché WSL traduce la working
directory. Se il repository è nel filesystem Linux (`~/...`), copia lo script o installa
`pwsh` (`sudo apt install -y powershell` dopo aver aggiunto il repo Microsoft).

### 1.2 Variabili di sessione

Ogni comando di questa guida usa queste variabili. Esportale una volta per shell — e
riesportale dopo ogni riapertura del terminale, perché non persistono:

```bash
export AWS_REGION=eu-south-1
export AWS_DEFAULT_REGION=eu-south-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export REPO_ROOT=$(git rev-parse --show-toplevel)
echo "account=$ACCOUNT_ID region=$AWS_REGION repo=$REPO_ROOT"
```

Esportare `AWS_REGION` evita di ripetere `--region` su ogni comando `aws` ed è ciò che
rende i blocchi seguenti copiabili senza modifiche. Per renderle permanenti, aggiungile a
`~/.bashrc` — tranne `ACCOUNT_ID`, che richiede credenziali valide al momento della
valutazione.

### 1.3 Account e credenziali

- Un account AWS dedicato alla PoC. Il prefisso risorse sarà `reverse-dr-poc`
  (`project_name`-`environment`); su un account condiviso i nomi non collidono (i bucket
  includono account ID e regione) ma i costi sì.
- **Credenziali temporanee via SSO o assume-role.** Mai chiavi statiche in `.tfvars`.
  L'unica verifica che conta:
  ```bash
  aws sts get-caller-identity
  ```
  Se risponde con l'account atteso, sei autenticato e non serve altro. Altrimenti
  autenticati con un profilo SSO realmente configurato (`aws configure list-profiles` li
  elenca):
  ```bash
  aws sso login --profile <nome-profilo-esistente>
  export AWS_PROFILE=<nome-profilo-esistente>
  ```
- Il principal che esegue Terraform ha bisogno di permessi di creazione su EC2/VPC, EKS,
  RDS, S3, ECR, IAM (ruoli e policy), EventBridge, SQS, Lambda, Secrets Manager,
  CloudWatch Logs.

### 1.4 Abilitare `eu-south-1` — passo obbligato, non opzionale

Milano è una regione **opt-in**: come tutte quelle lanciate dopo marzo 2019, nasce
disabilitata in ogni account. Finché non è abilitata, ogni chiamata verso `eu-south-1`
fallisce, e in modo poco leggibile (errori di endpoint o di token non valido, non un
messaggio esplicito "regione disabilitata").

```bash
aws account get-region-opt-status --region-name eu-south-1
```

Se lo stato è `DISABLED`:

```bash
aws account enable-region --region-name eu-south-1
```

L'abilitazione è asincrona: passa per `ENABLING` e richiede fino a qualche minuto. Attendi
che diventi `ENABLED` prima di proseguire:

```bash
until [ "$(aws account get-region-opt-status --region-name eu-south-1 --query RegionOptStatus --output text)" = "ENABLED" ]; do
  echo "in attesa..."; sleep 30
done
echo "eu-south-1 abilitata"
```

**In un account dentro una AWS Organization l'abilitazione può essere riservata al
management account.** Se ricevi un `AccessDenied`, non è un problema di
`AdministratorAccess`: è una decisione presa a livello di organizzazione, e va chiesta al
team che la governa. È lo stesso meccanismo che ha negato `PutBucketPublicAccessBlock`
al §1.5.

### 1.5 Verifica di disponibilità dei servizi in `eu-south-1`

Milano non offre tutti i servizi di Irlanda, e le famiglie di istanze variano per regione.
Verificalo adesso, non a metà di un apply:

```bash
# EKS raggiungibile (una lista vuota è una risposta valida)
aws eks list-clusters

# Instance type usati dallo stack: t3.medium per i nodi, t4g.nano per la NAT
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=t3.medium,t4g.nano \
  --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output table

# Classe RDS
aws rds describe-orderable-db-instance-options \
  --engine postgres --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[0].EngineVersion' --output text

# AZ disponibili: la prima sarà quella dei workload, la seconda la witness
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' --output table
```

Se `t4g.nano` non compare, la NAT instance ARM non è ordinabile: ripiega su `t3.nano`
(x86) impostando `nat_instance_type = "t3.nano"` e **rimuovendo** `nat_ami_id`, perché lo
stack seleziona per default una AMI Amazon Linux 2023 **arm64**. Cambiare architettura
senza cambiare AMI produce un'istanza che non parte, senza errori Terraform.

### 1.6 Bucket di state (pre-esistente, creato una volta)

Terraform non può creare il backend di sé stesso. Il bucket va creato fuori dallo stack,
versionato e cifrato. Il nome deve essere globalmente unico su tutto S3: l'account ID
basta a garantirlo, senza inventarsi un suffisso random.

**Il bucket di state sta di proposito in `eu-west-1`, non in `eu-south-1`.** La regione del
backend è indipendente da quella delle risorse, e in un progetto di disaster recovery
tenere lo state fuori dalla regione dei workload è la scelta coerente: se `eu-south-1`
diventa irraggiungibile, lo state con cui gestisci l'infrastruttura resta leggibile. È una
divergenza voluta fra `backend.hcl` (`region = "eu-west-1"`) e `terraform.tfvars`
(`aws_region = "eu-south-1"`), non una svista.

```bash
export TFSTATE_BUCKET="tesi-reverse-dr-tfstate-${ACCOUNT_ID}"
export TFSTATE_REGION=eu-west-1
echo "$TFSTATE_BUCKET"

aws s3api create-bucket \
  --bucket "$TFSTATE_BUCKET" \
  --region "$TFSTATE_REGION" \
  --create-bucket-configuration LocationConstraint="$TFSTATE_REGION"

aws s3api put-bucket-versioning \
  --bucket "$TFSTATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$TFSTATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$TFSTATE_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

`--create-bucket-configuration` serve per ogni regione diversa da `us-east-1`; ometterlo
crea il bucket nella regione sbagliata.

**Se ricevi `OperationAborted: A conflicting conditional operation is currently in
progress`**, il bucket con quel nome esiste già: i nomi S3 sono globali, quindi non puoi
"ricrearlo" in un'altra regione. Non è un errore transitorio da ritentare e non c'è motivo
di cancellarlo. Verifica dove si trova e usa quello:

```bash
aws s3api get-bucket-location --bucket "$TFSTATE_BUCKET" --output text
export TFSTATE_REGION=$(aws s3api get-bucket-location --bucket "$TFSTATE_BUCKET" --output text)
```

`get-bucket-location` restituisce `None` per `us-east-1`: in quel caso `TFSTATE_REGION`
va impostata a mano a `us-east-1`.

**Se l'ultimo comando fallisce con `AccessDenied ... explicit deny in a service control
policy`, non aggirarlo.** In un account dentro una AWS Organization il blocco degli accessi
pubblici è tipicamente imposto a livello di account e l'SCP nega le modifiche per bucket,
proprio perché nessuno possa indebolirlo. Dal 2023 i bucket nuovi nascono già bloccati:
il comando è ridondante, verifica lo stato invece di forzarlo.

```bash
aws s3api get-bucket-versioning --bucket "$TFSTATE_BUCKET"    # Status: Enabled
aws s3api get-bucket-encryption --bucket "$TFSTATE_BUCKET"    # SSEAlgorithm: AES256
aws s3api get-public-access-block --bucket "$TFSTATE_BUCKET"  # quattro flag true
aws s3control get-public-access-block --account-id "$ACCOUNT_ID"
```

`put-bucket-versioning` e `put-bucket-encryption` non stampano nulla quando riescono: il
silenzio è successo.

Il versioning non è cosmetico: è l'unico rollback disponibile se uno state viene corrotto
o troncato. `use_lockfile = true` sostituisce la vecchia tabella DynamoDB di lock, quindi
non serve crearla.

> **Il bucket è l'unica risorsa di questa guida che non vive in `eu-south-1`.** Ogni altro
> comando usa `$AWS_REGION`; qui e solo qui vale `$TFSTATE_REGION`.

---

## 2. Dipendenza a monte — Entra ID

**Perché prima:** il ConfigMap cloud (`infra/aws/kubernetes/configmap.yaml`) contiene
issuer, client ID, audience e endpoint OIDC. Senza gli output Entra non è renderizzabile,
e il BFF non parte.

Il provider `azuread` non usa le credenziali AWS: serve un'autenticazione Azure separata.

```bash
az login --use-device-code
az account show --query tenantId --output tsv
```

```bash
cd "$REPO_ROOT/automazione/infra/entra"
cp terraform.tfvars.example terraform.tfvars
# Sostituire tenant, URI di callback e object ID nel file locale non versionato.
terraform init
terraform validate
terraform test
terraform plan -out=entra.tfplan
```

`terraform.tfvars` è caricato automaticamente: qui `-var-file` non serve.

| Campo di `terraform.tfvars` | Valore |
|---|---|
| `tenant_id` | output di `az account show --query tenantId -o tsv` |
| `bff_redirect_uri` | `https://<hostname>/api/v1/auth/callback` |
| `bff_logout_uri` | `https://<hostname>/` |
| `role_assignments` | object ID Entra di utenti o gruppi, mai email o display name. Vuoto = fail-closed |

> **Decidi ora l'hostname applicativo.** È lo stesso del certificato ACM e del record DNS
> del §8, ed Entra pretende un redirect URI esatto. Cambiarlo dopo significa rifare
> application registration e certificato.

Due differenze rispetto allo stack AWS, entrambe deliberate:

- **Lo state è locale**: non esiste un blocco `backend`. Non contiene segreti, ma contiene
  gli ID delle application registration ed è l'unico modo per gestirle in futuro. Non
  perderlo e non committarlo.
- **I permessi richiesti sono nel tenant Entra**, non nell'account AWS:
  `Application.ReadWrite.OwnedBy`, più `AppRoleAssignment.ReadWrite.All` e
  `Application.Read.All` solo se `role_assignments` non è vuoto. Su un tenant aziendale
  raramente li hai di default: verificalo prima del plan.

**⚠️ APPLY** — dopo review e approvazione del tenant owner:

```bash
terraform apply entra.tfplan
terraform output -json oidc_runtime_config
terraform output -raw api_audience
```

Salva gli output fuori dal repository, per il rendering del §9:

```bash
mkdir -p ~/.reverse-dr && chmod 700 ~/.reverse-dr
terraform output -json > ~/.reverse-dr/entra-outputs.json
```

Due cose vanno fatte a mano dopo l'apply, perché Terraform non le crea di proposito:

1. **Admin consent** dello scope delegato `access_as_user` sulla BFF application, dal
   portale Entra. Senza, il code exchange fallisce.
2. **Credenziale confidenziale del BFF** (`OIDC_CLIENT_SECRET` o, meglio, un certificato).
   Generarla fuori da Terraform e portarla direttamente in Secrets Manager al §5 — mai in
   `.tfvars`, output o log.

> **Contratto condiviso col DR.** `api_audience` è un GUID, non `api://...`. Lo stesso
> GUID deve comparire nel realm Keycloak DR (`infra/onprem/keycloak/realm/`), altrimenti
> il failover rompe l'autorizzazione in silenzio ([`CLAUDE.md`](../CLAUDE.md) §5).

---

## 3. Validazione statica (offline, nessun costo)

Questa fase non tocca AWS e va superata prima di guardare un piano.

```bash
cd "$REPO_ROOT/automazione/infra/aws"
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars

sed -i \
  -e "s|^bucket .*|bucket         = \"${TFSTATE_BUCKET}\"|" \
  -e "s|^region .*|region         = \"${TFSTATE_REGION}\"|" \
  backend.hcl
grep -E '^(bucket|region)' backend.hcl

terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

Lo script di contratto statico è PowerShell e si esegue via interoperabilità WSL:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/static_contract.ps1
```

`terraform test` gira su provider mock e verifica le decisioni architetturali, non la
sintassi: che il node group stia in una sola subnet, che RDS non sia multi-AZ, che le
subnet witness restino minime. `static_contract.ps1` verifica gli stessi invarianti sul
testo dei file. Se falliscono dopo una tua modifica, la modifica ha violato una scelta
dichiarata — vedi [`CLAUDE.md`](../CLAUDE.md) §3 e §8 prima di "aggiustare il test".

### Valori da sostituire in `terraform.tfvars`

| Variabile | Valore per questa PoC | Nota |
|---|---|---|
| `aws_region` | `"eu-south-1"` | deve combaciare con `$AWS_REGION` della sessione |
| `availability_zones` | `["eu-south-1a", "eu-south-1b"]` | **ordine significativo**: prima la AZ dei workload, poi la witness. Usa i nomi reali visti al §1.5 |
| `eks_admin_principal_arns` | ARN del tuo ruolo SSO | vuoto = nessun amministratore umano, cluster inaccessibile |
| `eks_public_access_cidrs` | il tuo IP `/32` | il default `203.0.113.10/32` è un IP documentale RFC 5737 |
| `database_deletion_protection` | `false` per la PoC | `true` se il DB deve sopravvivere a un `destroy` accidentale |
| `bucket_force_destroy` | `false` | lasciare `false`: `true` cancella i backup insieme allo stack |

L'ARN da mettere in `eks_admin_principal_arns` non è quello che stampa
`get-caller-identity` (che è un `assumed-role/.../sessione`): serve l'ARN del **ruolo**,
senza la sessione.

```bash
aws sts get-caller-identity --query Arn --output text \
  | sed -E 's|:sts:|:iam:|; s|:assumed-role/([^/]+)/.*|:role/\1|'
```

Per un ruolo SSO l'ARN reale include il path `/aws-reserved/sso.amazonaws.com/...`.
Ottienilo con:

```bash
aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
  --query 'Roles[?starts_with(RoleName, `AWSReservedSSO_AdministratorAccess`)].Arn' --output text
```

Su `eks_endpoint_public_access` (default `false`) vedi §6: la scelta condiziona come
raggiungerai il cluster.

---

## 4. Piano e apply dell'infrastruttura base

### 4.0 Se l'account è dentro una AWS Organization

Un `AdministratorAccess` non è la parola finale: le **Service Control Policy** dell'account
padre si applicano prima, e producono `explicit deny in a service control policy` anche a
un amministratore. Dal member account non puoi leggerne il contenuto — serve accesso al
management account.

`terraform plan` **non le rileva**: il piano è una previsione, le SCP mordono in fase di
apply. Le risorse di questo stack più esposte a un deny, in ordine di probabilità:

| Risorsa | SCP che tipicamente la blocca |
|---|---|
| Uso di `eu-south-1` | allow-list di regioni approvate — la più probabile su una regione opt-in |
| Elastic IP + NAT instance con IP pubblico | divieto di indirizzi pubblici fuori da subnet approvate |
| Ruoli IAM (IRSA, node, controller ALB) | obbligo di permissions boundary sui ruoli creati |
| Node group EC2 | allow-list di instance type o divieto di famiglie non approvate |
| EKS con endpoint pubblico | divieto di endpoint di controllo esposti |

Prima di un apply da 20 minuti che fallisce a metà, conviene chiedere al team cloud quali
SCP si applicano all'account. Un apply parziale lascia risorse orfane da rimuovere a mano
e lo state Terraform disallineato.

### 4.1 Piano

```bash
cd "$REPO_ROOT/automazione/infra/aws"
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -var-file=terraform.tfvars -out=reverse-dr-poc.tfplan
terraform show -no-color reverse-dr-poc.tfplan > plan.txt
```

Cosa controllare in `plan.txt` prima di procedere — non è una formalità:

```bash
grep -c "will be created" plan.txt                 # ordine di grandezza atteso: 70-90
grep -n "multi_az" plan.txt                        # deve essere false
grep -n "nat_gateway" plan.txt                     # non deve trovare nulla
grep -n "eu-south-1" plan.txt | head               # regione coerente ovunque
grep -n '"Resource": *"\*"' plan.txt               # solo dentro la policy del controller ALB
```

**⚠️ APPLY**

```bash
terraform apply reverse-dr-poc.tfplan
```

Tempi indicativi: il control plane EKS richiede ~10 minuti, il node group altri ~3, RDS
~8. L'apply completo si assesta intorno ai 20-25 minuti. È normale che sembri fermo
durante la creazione del cluster.

Salva gli output subito dopo, **fuori dal repository** — `terraform output -json` include
anche i valori marcati `sensitive`:

```bash
mkdir -p ~/.reverse-dr && chmod 700 ~/.reverse-dr
umask 077
terraform output -json > ~/.reverse-dr/aws-outputs.json
jq 'keys' ~/.reverse-dr/aws-outputs.json
```

> **Nota sull'ordine.** La Lambda di automazione resta disabilitata a questo apply:
> `automation_lambda_image_uri = null`. Non è una dimenticanza, è una circolarità — l'URI
> punta a un'immagine in un repository ECR che questo stesso apply crea. La Lambda si
> abilita con un secondo apply al §11.

---

## 5. Bootstrap dei segreti

Terraform ha creato due contenitori vuoti in Secrets Manager e la password master di RDS
(gestita da RDS stesso, illeggibile ai ruoli applicativi). Ora vanno riempiti:

| Secret | Chiavi attese | Consumatore |
|---|---|---|
| `.../application/database` | `DATABASE_URL` | BFF, ticket, automation, CronJob backup |
| `.../application/config` | `OIDC_CLIENT_SECRET`, `SESSION_ENCRYPTION_KEY` | solo BFF |

### 5.1 Perché serve un pod, non la tua shell

L'istanza RDS ha `publicly_accessible = false` e un security group che accetta traffico
5432 **solo** dal security group del cluster EKS. Non è raggiungibile da WSL, né dalla NAT
instance (che non ha SSH). La creazione dell'utente applicativo va fatta da dentro il
cluster: **esegui prima il §6**, poi torna qui.

### 5.2 Utente PostgreSQL applicativo ristretto

L'utente master (`platform_admin`) non deve essere usato dai workload. Crea un utente
dedicato con i soli privilegi necessari:

```bash
cd "$REPO_ROOT/automazione/infra/aws"
umask 077

MASTER_SECRET_ARN=$(terraform output -raw database_master_secret_arn)
MASTER_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET_ARN" --query SecretString --output text | jq -r .password)
RDS_HOST=$(terraform output -raw database_endpoint)
DB_NAME=$(terraform output -raw database_name)
APP_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)

MASTER_URL="postgresql://platform_admin:$(printf '%s' "$MASTER_PASSWORD" | jq -sRr @uri)@${RDS_HOST}/${DB_NAME}?sslmode=require"
```

Le credenziali passano al pod tramite un Secret temporaneo, mai in `argv` né nel manifest:

```bash
kubectl create namespace helios-desk --dry-run=client -o yaml | kubectl apply -f -

kubectl -n helios-desk create secret generic pg-bootstrap \
  --from-literal=MASTER_URL="$MASTER_URL" \
  --from-literal=APP_PASSWORD="$APP_PASSWORD"

kubectl -n helios-desk run pg-bootstrap --rm -i --restart=Never \
  --image=postgres:16-alpine \
  --overrides='{"spec":{"containers":[{"name":"pg","image":"postgres:16-alpine","command":["sh","-c","psql \"$MASTER_URL\" -v ON_ERROR_STOP=1 -v pw=\"$APP_PASSWORD\" -f -"],"stdin":true,"envFrom":[{"secretRef":{"name":"pg-bootstrap"}}]}]}}' <<'SQL'
CREATE ROLE helios_app LOGIN PASSWORD :'pw';
GRANT CONNECT ON DATABASE helios TO helios_app;
GRANT USAGE, CREATE ON SCHEMA public TO helios_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO helios_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO helios_app;
SQL

kubectl -n helios-desk delete secret pg-bootstrap
unset MASTER_PASSWORD MASTER_URL
```

`CREATE` su `public` serve perché le migrazioni (§10) girano con questo utente. Separare
un utente DDL da uno DML è un miglioramento legittimo, ma allora le migrazioni vanno
eseguite con credenziali diverse dal runtime.

### 5.3 Popolare i due secret

I valori passano da file temporanei con permessi ristretti, mai da `argv`:

```bash
umask 077
CONFIG_SECRET_ARN=$(terraform output -json application_secret_arns | jq -r .config)
DB_SECRET_ARN=$(terraform output -json application_secret_arns | jq -r .database)

# Il client secret del BFF Entra viene richiesto interattivamente: non finisce
# nella cronologia della shell.
read -rsp "OIDC_CLIENT_SECRET del BFF Entra: " OIDC_CLIENT_SECRET; echo

jq -n --arg url "postgresql+asyncpg://helios_app:${APP_PASSWORD}@${RDS_HOST}/${DB_NAME}?ssl=require" \
  '{DATABASE_URL:$url}' > /tmp/db-secret.json

jq -n --arg cs "$OIDC_CLIENT_SECRET" --arg key "$(openssl rand -base64 48)" \
  '{OIDC_CLIENT_SECRET:$cs, SESSION_ENCRYPTION_KEY:$key}' > /tmp/config-secret.json

aws secretsmanager put-secret-value --secret-id "$DB_SECRET_ARN"     --secret-string file:///tmp/db-secret.json
aws secretsmanager put-secret-value --secret-id "$CONFIG_SECRET_ARN" --secret-string file:///tmp/config-secret.json

shred -u /tmp/db-secret.json /tmp/config-secret.json
unset APP_PASSWORD OIDC_CLIENT_SECRET
```

Lo schema `postgresql+asyncpg://` è quello atteso da SQLAlchemy async; il CronJob di
backup lo riscrive in memoria a `postgresql://` prima di invocare `pg_dump`, quindi il
formato è corretto per entrambi i consumatori.

> **Limite dichiarato, non nascosto:** la rotazione di questi due secret non è
> automatizzata. Secrets Manager la supporta via Lambda di rotazione, ma la PoC non la
> configura. Va gestita a mano, o dichiarata come limite in tesi.

---

## 6. Accesso al cluster EKS

```bash
cd "$REPO_ROOT/automazione/infra/aws"
aws eks update-kubeconfig --name "$(terraform output -raw eks_cluster_name)"
kubectl get nodes
```

`--region` non serve: `$AWS_REGION` è esportata dal §1.2.

Se `kubectl` va in timeout, la causa è quasi sempre una delle due:

**a) Non sei nell'access entry.** `authentication_mode = "API"` significa che `aws-auth`
non conta: solo gli ARN in `eks_admin_principal_arns` hanno accesso, e la lista è vuota di
default. Verifica cosa il cluster riconosce davvero:

```bash
aws eks list-access-entries --cluster-name "$(terraform output -raw eks_cluster_name)"
```

Se il tuo ruolo non c'è, aggiungilo al `.tfvars` (§3) e rifai plan/apply.

**b) L'endpoint è privato.** Con `eks_endpoint_public_access = false` (default) l'API
server risponde solo da dentro la VPC. Tre opzioni, in ordine di pulizia decrescente:

| Opzione | Costo | Nota |
|---|---|---|
| Bastion EC2 nella subnet pubblica + SSM Session Manager port forwarding | basso, temporaneo | non richiede SSH né chiavi; è l'opzione consigliata |
| Client VPN | alto (costo orario per endpoint e per connessione) | sovradimensionato per una PoC |
| `eks_endpoint_public_access = true` + `eks_public_access_cidrs = ["<tuo-IP>/32"]` | zero | pragmatico, ma espone l'API server: usalo solo se accetti e **dichiari** il trade-off |

Il tuo IP pubblico corrente, da WSL:

```bash
curl -s https://checkip.amazonaws.com
```

Attenzione: da WSL l'IP è quello della connessione Windows sottostante, e su una rete
aziendale cambia con il gateway di uscita. Un `/32` che oggi funziona domani può non
funzionare più — un altro motivo per preferire il bastion.

La terza opzione è quella che la maggior parte delle PoC sceglie. Se la scegli, scrivilo:
è esattamente il tipo di scelta che va motivata invece che subita.

---

## 7. Build e push delle immagini in ECR

Sei immagini, cinque repository creati da Terraform. I nomi vengono dagli output, non
ricostruiti a mano:

```bash
cd "$REPO_ROOT/automazione/infra/aws"
terraform output -json ecr_repository_urls | jq
```

Login al registry:

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
```

I repository sono `IMMUTABLE`: un tag già pubblicato non si sovrascrive. Usa un tag
derivato dal commit, non `latest`:

```bash
cd "$REPO_ROOT"
export TAG=$(git rev-parse --short HEAD)
export BACKUP_TAG="backup-${TAG}"
BACKEND="automazione/apps/backend"
echo "tag=$TAG registry=$REGISTRY"
```

### 7.1 I quattro servizi applicativi

Il contesto di build del backend è `apps/backend`, non la directory del singolo servizio —
i servizi condividono `src/` e `requirements.txt`:

```bash
cd "$REPO_ROOT"
docker build -t "$REGISTRY/reverse-dr-poc-bff:$TAG"        -f "$BACKEND/services/bff/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/reverse-dr-poc-ticket:$TAG"     -f "$BACKEND/services/ticket-service/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/reverse-dr-poc-automation:$TAG" -f "$BACKEND/services/automation-service/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/reverse-dr-poc-frontend:$TAG"   automazione/apps/frontend

for repo in bff ticket automation frontend; do
  docker push "$REGISTRY/reverse-dr-poc-$repo:$TAG"
done
```

Il frontend non ha bisogno di variabili di build: `runtime-config.json` è generato
all'avvio del container da `deploy/40-runtime-config.sh`, quindi la stessa immagine gira
identica su AWS e on-prem. È una scelta voluta, non un dettaglio.

**Architettura:** i nodi EKS sono `t3.medium`, quindi x86-64. Se costruisci da un WSL su
Windows ARM, aggiungi `--platform linux/amd64` a ogni `docker build`, altrimenti i pod
entrano in `CrashLoopBackOff` con `exec format error`.

### 7.2 La function `ticket-processor`

Il suo Dockerfile fa `COPY automazione/apps/functions/...`, quindi il contesto di build è
la **root del repository**:

```bash
cd "$REPO_ROOT"
docker build -t "$REGISTRY/reverse-dr-poc-ticket-processor:$TAG" \
  -f automazione/apps/functions/ticket-processor/Dockerfile .
docker push "$REGISTRY/reverse-dr-poc-ticket-processor:$TAG"
```

L'immagine base AWS Lambda include già il Runtime Interface Emulator: lo stesso artefatto
gira su AWS Lambda nel primario e sotto `lambda-dr` nel sito DR. Non costruirne due
versioni.

### 7.3 L'immagine di backup — **da costruire, non esiste nel repo**

`backup-cronjob.yaml` referenzia `helios-postgres-backup` e la `kustomization.yaml` la
mappa sul repository `automation` con un tag dedicato (`REPLACE_BACKUP_IMAGE_TAG`). **Nel
repository non c'è un Dockerfile per questa immagine**: è una lacuna reale, non una svista
da ignorare. Il CronJob ha bisogno di `pg_dump` **e** `psql` (per scrivere
`backup.last_success` in `dr_telemetry`), AWS CLI v2, `sed`, `sha256sum`.

Crealo una volta:

```bash
mkdir -p "$REPO_ROOT/automazione/apps/backup"
cat > "$REPO_ROOT/automazione/apps/backup/Dockerfile" <<'DOCKERFILE'
# Immagine del CronJob di backup RDS -> S3.
# Deve contenere pg_dump E psql: il job che ha prodotto il backup e' l'unico
# componente titolato a dichiarare quando e' davvero riuscito, e lo fa scrivendo
# backup.last_success in dr_telemetry via psql.
FROM public.ecr.aws/docker/library/postgres:16-alpine
RUN apk add --no-cache aws-cli coreutils
USER 70:70
DOCKERFILE

cd "$REPO_ROOT"
docker build -t "$REGISTRY/reverse-dr-poc-automation:$BACKUP_TAG" \
  -f automazione/apps/backup/Dockerfile automazione/apps/backup
docker push "$REGISTRY/reverse-dr-poc-automation:$BACKUP_TAG"
```

`postgres:16-alpine` come base non è arbitrario: la major di `pg_dump` deve essere `>=`
alla major del server RDS (`database_engine_version = "16"`), altrimenti il dump fallisce
con un errore di versione. Se aggiorni la major di RDS, aggiorna anche questa immagine.

---

## 8. Certificato ACM e DNS (out-of-band)

L'ALB nasce dall'Ingress, ma l'Ingress ha bisogno dell'ARN di un certificato **già
esistente e già validato**, in `eu-south-1` (non `us-east-1`, che serve solo a CloudFront).

Ordine obbligato — è un uovo/gallina che va risolto in questo verso:

```bash
export APP_HOST=<hostname-scelto>          # es. helios.tuodominio.example
```

1. richiedi il certificato:
   ```bash
   CERT_ARN=$(aws acm request-certificate \
     --domain-name "$APP_HOST" \
     --validation-method DNS \
     --query CertificateArn --output text)
   echo "$CERT_ARN"
   ```
2. leggi il record di validazione e crealo nel DNS che possiedi:
   ```bash
   aws acm describe-certificate --certificate-arn "$CERT_ARN" \
     --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output table
   ```
3. attendi l'emissione:
   ```bash
   aws acm wait certificate-validated --certificate-arn "$CERT_ARN"
   aws acm describe-certificate --certificate-arn "$CERT_ARN" --query 'Certificate.Status' --output text
   ```
4. renderizza e applica l'Ingress (§9) usando `$CERT_ARN` e `$APP_HOST`;
5. **solo dopo** l'ALB esiste e ha un hostname: crea il record `CNAME` dal tuo hostname
   verso
   ```bash
   kubectl -n helios-desk get ingress helios-public \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
   ```

L'hostname deve essere HTTPS e stabile perché il BFF usa cookie `__Host-*`, che richiedono
`Secure`, path `/` e nessun `Domain`: un accesso via IP o via hostname ALB grezzo in HTTP
rompe il login, non lo degrada.

Il redirect URI registrato in Entra (§2) deve essere esattamente
`https://$APP_HOST/api/v1/auth/callback`. Se lo cambi qui, cambialo lì.

---

## 9. Componenti di piattaforma e overlay applicativo

### 9.1 External Secrets Operator (prima di tutto il resto)

I CRD `SecretStore` e `ExternalSecret` devono esistere prima del kustomization, altrimenti
l'apply fallisce a metà.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  -f "$REPO_ROOT/automazione/infra/aws/kubernetes/external-secrets-values.yaml.example"

kubectl -n external-secrets rollout status deploy/external-secrets
```

Una replica sola è una scelta di costo dichiarata nel README, non una svista.

### 9.2 AWS Load Balancer Controller

Compila service account e values a partire dagli output, senza editing manuale:

```bash
cd "$REPO_ROOT/automazione/infra/aws"
K8S_DIR="$REPO_ROOT/automazione/infra/aws/kubernetes"
WORK=~/.reverse-dr/render && mkdir -p "$WORK"

LBC_ROLE_ARN=$(terraform output -raw load_balancer_controller_role_arn)
VPC_ID=$(terraform output -raw vpc_id)
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)

sed "s|REPLACE_LOAD_BALANCER_CONTROLLER_ROLE_ARN|${LBC_ROLE_ARN}|" \
  "$K8S_DIR/aws-load-balancer-controller-serviceaccount.yaml" > "$WORK/alb-sa.yaml"
kubectl -n kube-system apply -f "$WORK/alb-sa.yaml"

sed -e "s|REPLACE_VPC_ID|${VPC_ID}|" \
    -e "s|^clusterName:.*|clusterName: ${CLUSTER_NAME}|" \
    -e "s|^region:.*|region: ${AWS_REGION}|" \
  "$K8S_DIR/aws-load-balancer-controller-values.yaml.example" > "$WORK/alb-values.yaml"

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system -f "$WORK/alb-values.yaml"

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

La policy IAM creata da Terraform è derivata da quella ufficiale del controller `v3.4.2`.
Installare una versione del chart più recente senza verificare il delta di permessi
produce errori difficili da diagnosticare: il controller logga un `AccessDenied` e
l'Ingress resta senza indirizzo.

### 9.3 Rendering dell'overlay

I manifest in `infra/aws/kubernetes/` sono template con placeholder `REPLACE_*` e **non
vanno applicati direttamente**. Si lavora su una copia fuori dal repository:

```bash
cd "$REPO_ROOT/automazione/infra/aws"
OVERLAY=~/.reverse-dr/overlay && rm -rf "$OVERLAY" && mkdir -p "$OVERLAY"
cp "$K8S_DIR"/*.yaml "$OVERLAY/"
rm -f "$OVERLAY/aws-load-balancer-controller-serviceaccount.yaml"

AWS_OUT=~/.reverse-dr/aws-outputs.json
ENTRA_OUT=~/.reverse-dr/entra-outputs.json

ECR=$(jq -r '.ecr_repository_urls.value' "$AWS_OUT")
IRSA=$(jq -r '.workload_irsa_role_arns.value' "$AWS_OUT")
OIDC=$(jq -r '.oidc_runtime_config.value' "$ENTRA_OUT")

sed -i \
  -e "s|REPLACE_AWS_REGION|${AWS_REGION}|g" \
  -e "s|REPLACE_FRONTEND_ECR_REPOSITORY|$(jq -r .frontend <<<"$ECR")|g" \
  -e "s|REPLACE_BFF_ECR_REPOSITORY|$(jq -r .bff <<<"$ECR")|g" \
  -e "s|REPLACE_TICKET_ECR_REPOSITORY|$(jq -r .ticket <<<"$ECR")|g" \
  -e "s|REPLACE_AUTOMATION_ECR_REPOSITORY|$(jq -r .automation <<<"$ECR")|g" \
  -e "s|REPLACE_BACKUP_IMAGE_TAG|${BACKUP_TAG}|g" \
  -e "s|REPLACE_IMAGE_TAG|${TAG}|g" \
  -e "s|REPLACE_BFF_IRSA_ROLE_ARN|$(jq -r '."helios-bff"' <<<"$IRSA")|g" \
  -e "s|REPLACE_TICKET_IRSA_ROLE_ARN|$(jq -r '."helios-ticket-service"' <<<"$IRSA")|g" \
  -e "s|REPLACE_AUTOMATION_IRSA_ROLE_ARN|$(jq -r '."helios-automation-service"' <<<"$IRSA")|g" \
  -e "s|REPLACE_BACKUP_IRSA_ROLE_ARN|$(jq -r '."helios-postgres-backup"' <<<"$IRSA")|g" \
  -e "s|REPLACE_APPLICATION_DATABASE_SECRET_ARN|$(jq -r '.application_secret_arns.value.database' "$AWS_OUT")|g" \
  -e "s|REPLACE_APPLICATION_CONFIG_SECRET_ARN|$(jq -r '.application_secret_arns.value.config' "$AWS_OUT")|g" \
  -e "s|REPLACE_BACKUP_BUCKET_NAME|$(jq -r '.backup_bucket_name.value' "$AWS_OUT")|g" \
  -e "s|REPLACE_ACM_CERTIFICATE_ARN|${CERT_ARN}|g" \
  -e "s|REPLACE_APP_HOSTNAME|${APP_HOST}|g" \
  "$OVERLAY"/*.yaml
```

Le chiavi esatte di `IRSA` e `ECR` dipendono dagli output: verificale con
`jq 'keys' <<<"$ECR"` e `jq 'keys' <<<"$IRSA"` prima di eseguire il `sed`, e adegua i
nomi se differiscono.

I placeholder Entra (`REPLACE_ENTRA_*`) vanno sostituiti dai campi di `$OIDC`, che ha una
struttura decisa dallo stack `infra/entra`: ispezionala e mappala esplicitamente, invece
di indovinarla.

```bash
jq . <<<"$OIDC"
```

Verifica che non sia rimasto nulla, poi renderizza:

```bash
cd "$OVERLAY"
grep -rn "REPLACE_" . && echo "PLACEHOLDER RESIDUI — fermati qui" || echo "nessun placeholder residuo"
kubectl kustomize . > rendered.yaml
kubeconform -strict -summary -ignore-missing-schemas rendered.yaml
```

Ispeziona `rendered.yaml` prima di applicare: non deve contenere nessun valore segreto —
solo ARN e riferimenti a `ExternalSecret`. Se ci trovi una password, il flusso dei segreti
è stato aggirato da qualche parte.

```bash
grep -inE "password|secret_key|BEGIN (RSA|EC|PRIVATE)" rendered.yaml
```

### 9.4 Apply

**⚠️ APPLY**

```bash
kubectl apply -f "$OVERLAY/rendered.yaml"
kubectl -n helios-desk get externalsecret     # tutti SecretSynced
kubectl -n helios-desk get pods -w
```

Se un `ExternalSecret` resta in `SecretSyncError`, l'ordine di debug è: annotazione IRSA
sul service account → trust policy del ruolo (`sub` deve combaciare esattamente con
`system:serviceaccount:helios-desk:<nome>`) → chiavi presenti nel secret AWS.

```bash
kubectl -n helios-desk describe externalsecret helios-bff-database | tail -20
```

I pod partiranno in `CrashLoopBackOff` finché le tabelle non esistono: il §10 è il passo
mancante, non un errore.

---

## 10. Schema del database

Le immagini dei servizi **non** eseguono migrazioni all'avvio: nessun initContainer,
nessun entrypoint di migrazione. È una scelta deliberata (lo schema non va modificato da N
repliche in parallelo), e implica che vada applicato esplicitamente.

Le quattro migrazioni sono le stesse usate on-prem, nello stesso ordine:

```
apps/backend/services/ticket-service/migrations/001_initial.sql
apps/backend/services/bff/migrations/001_initial.sql
apps/backend/services/bff/migrations/002_dr_telemetry.sql
apps/backend/services/automation-service/migrations/001_initial.sql
```

Lo script `infra/onprem/scripts/apply-migrations.sh` implementa esattamente questa sequenza
(ConfigMap con i quattro file + Job `psql`), ma **non è riutilizzabile tale e quale su
AWS**: `DB_SECRET` è hardcoded a `helios-app-database`, il nome materializzato on-prem,
mentre su AWS External Secrets produce un Secret per workload (`helios-bff-database`,
`helios-ticket-database`, ...). Due strade:

- rendere `DB_SECRET` sovrascrivibile nello script
  (`DB_SECRET="${DB_SECRET:-helios-app-database}"`) e invocarlo con
  `DB_SECRET=helios-bff-database bash infra/onprem/scripts/apply-migrations.sh`;
- oppure replicare il Job a mano, mantenendo la stessa lista ordinata di file.

Le migrazioni usano `CREATE TABLE IF NOT EXISTS`, quindi sono idempotenti e sicure da
rieseguire.

`002_dr_telemetry.sql` non è opzionale: crea la tabella `dr_telemetry` in cui il CronJob di
backup scrive `backup.last_success` e il playbook di failover scrive
`failover.last_promotion`. Senza quella tabella la dashboard mostra `unknown` per RPO e
RTO — che è l'esito onesto di "mai misurato", non un bug da mascherare con un default
numerico.

Dopo le migrazioni, riavvia i workload:

```bash
kubectl -n helios-desk rollout restart deploy/helios-bff deploy/helios-ticket-service deploy/helios-automation-service
kubectl -n helios-desk rollout status deploy/helios-bff
```

---

## 11. Abilitare la Lambda di automazione (secondo apply)

Ora che l'immagine `ticket-processor` è in ECR, la circolarità del §4 è risolta. Usa il
**digest**, non il tag — Lambda risolve il tag una sola volta alla creazione, quindi un tag
è una falsa immutabilità:

```bash
DIGEST=$(aws ecr describe-images \
  --repository-name reverse-dr-poc-ticket-processor \
  --image-ids imageTag="$TAG" \
  --query 'imageDetails[0].imageDigest' --output text)

echo "automation_lambda_image_uri = \"${REGISTRY}/reverse-dr-poc-ticket-processor@${DIGEST}\""
```

Riporta la riga stampata in `terraform.tfvars`, insieme a:

```hcl
automation_lambda_architecture = "x86_64"
```

**⚠️ APPLY**

```bash
cd "$REPO_ROOT/automazione/infra/aws"
terraform plan -var-file=terraform.tfvars -out=lambda.tfplan
terraform show -no-color lambda.tfplan | grep -E "will be (created|destroyed|updated)"
terraform apply lambda.tfplan
```

Il piano deve toccare **solo** le risorse Lambda. Se propone di ricreare il node group o
l'RDS, qualcosa è cambiato nel `.tfvars` che non doveva cambiare: fermati e confronta.

Poi aggiorna il ConfigMap con il nome della function e riavvia l'automation service:

```bash
LAMBDA_NAME=$(terraform output -raw automation_lambda_function_name)
sed -i "s|REPLACE_AUTOMATION_LAMBDA_FUNCTION_NAME|${LAMBDA_NAME}|g" "$OVERLAY"/configmap.yaml
cd "$OVERLAY" && kubectl kustomize . > rendered.yaml && kubectl apply -f rendered.yaml
kubectl -n helios-desk rollout restart deploy/helios-automation-service
```

`AUTOMATION_MODE: aws-lambda` nel ConfigMap è il selettore di runtime: lo stesso codice
applicativo, su DR, legge `lambda-dr`. Il branching è nella configurazione del deployment,
mai nel codice della function ([`CLAUDE.md`](../CLAUDE.md) §3).

---

## 12. Verifica end-to-end

Nell'ordine, perché ogni passo dipende dal precedente:

```bash
# 1. Pod sani
kubectl -n helios-desk get pods
kubectl -n helios-desk exec deploy/helios-bff -- wget -qO- http://127.0.0.1:8000/health/ready
```

```bash
# 2. ALB provisionato e target sani
kubectl -n helios-desk get ingress helios-public
for TG in $(aws elbv2 describe-target-groups \
      --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-heliosde')].TargetGroupArn" \
      --output text); do
  echo "== $TG"
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
done
```

```bash
# 3. Frontend e API raggiungibili via HTTPS sull'hostname reale
curl -sSf "https://${APP_HOST}/healthz" && echo OK
curl -sS -o /dev/null -w '%{http_code}\n' "https://${APP_HOST}/api/v1/platform/status"
```

```bash
# 4. Login OIDC completo dal browser. Verifica che i cookie si chiamino __Host-*
#    e abbiano Secure e SameSite: un cookie senza __Host- significa che qualcosa
#    ha spostato il traffico fuori dall'origine canonica.
```

```bash
# 5. Backup: attendi un ciclo del CronJob (max 10 minuti)
kubectl -n helios-desk get cronjob helios-postgres-backup
aws s3 ls "s3://$(cd "$REPO_ROOT/automazione/infra/aws" && terraform output -raw backup_bucket_name)/postgres/"
```

```bash
# 6. Telemetria RPO: la dashboard deve smettere di mostrare "unknown"
curl -sS "https://${APP_HOST}/api/v1/platform/status" | jq
```

Il punto 6 è quello che chiude il cerchio con la tesi: `backup.last_success` viene scritta
in `dr_telemetry` **dopo** l'upload su S3, non dopo il dump. Se la vedi valorizzata, il
backup è davvero su S3 e davvero ripristinabile dal sito DR; se la si scrivesse dopo il
dump, misureresti un RPO che il DR non potrebbe rispettare.

---

## 13. Cosa il sito DR consuma da qui

Tre cose soltanto, ed è voluto — un accoppiamento più stretto renderebbe il DR dipendente
dal sito caduto:

| Cosa | Dove | Chi lo usa nel DR |
|---|---|---|
| Dump PostgreSQL + checksum | `s3://<backup-bucket>/postgres/` | `helpdesk-dr/scripts/restore/restore-onprem.sh` |
| Audience e ruoli Entra | output `api_audience`, permissions del contract | realm Keycloak `helios-desk` |
| Immagine `ticket-processor` | ECR (o la copia inline nel ConfigMap `lambda-dr`) | runtime RIE on-prem |

Il sito DR **non** dipende da Secrets Manager (usa OpenBao), né dall'API server EKS (che il
drill spegne di proposito), né da DNS AWS. Se durante il provisioning ti trovi ad aggiungere
una dipendenza del DR verso una risorsa AWS, quella dipendenza è un bug di architettura:
renderebbe il DR non attivabile esattamente quando serve.

> **Coerenza di regione.** I manifest `lambda-dr/kubernetes/*.yaml` impostano
> `AWS_REGION: eu-west-1` per soddisfare il runtime Lambda locale, che pretende una regione
> anche senza chiamare AWS. È inerte, ma resta un riferimento a una regione che questa PoC
> non usa più: allinealo a `eu-south-1` quando lavori sul sito DR.

---

## 14. Costi e teardown

L'ordine di grandezza è dominato dal control plane EKS, che si paga a ore
indipendentemente dal traffico. Verifica sempre su [AWS Pricing
Calculator](https://calculator.aws/): l'incidenza relativa attesa è nella tabella di
[`infra/aws/README.md`](infra/aws/README.md), stimata su `eu-west-1`. **Milano è
generalmente più cara di Irlanda**: rifai la stima con `eu-south-1` selezionata invece di
riusare quei numeri.

Per spegnere tutto tra una sessione e l'altra, la leva più efficace è azzerare il node
group senza distruggere lo stack (`eks_node_desired_size = 0`, `eks_node_min_size = 0`):
risparmi l'istanza EC2 ma continui a pagare control plane, RDS e ALB.

**Teardown completo** — irreversibile:

```bash
# 1. L'ALB non e' gestito da Terraform: va rimosso cancellando l'Ingress e
#    aspettando che il controller lo elimini, altrimenti la distruzione della
#    VPC fallisce con ENI orfane.
kubectl -n helios-desk delete ingress helios-public
sleep 60
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text

# 2. Salva i backup: sono l'unico artefatto che il sito DR puo' ripristinare.
cd "$REPO_ROOT/automazione/infra/aws"
aws s3 sync "s3://$(terraform output -raw backup_bucket_name)/postgres/" ~/.reverse-dr/backup-archive/

# 3. Distruzione
terraform destroy -var-file=terraform.tfvars
```

`bucket_force_destroy = false` blocca il destroy dei bucket non vuoti: è una protezione,
non un ostacolo. `database_deletion_protection` e `database_skip_final_snapshot` decidono
se resterà uno snapshot finale di RDS.

---

## 15. Checklist finale

- [ ] `eu-south-1` abilitata (`RegionOptStatus = ENABLED`) e servizi verificati
- [ ] Bucket di state creato, versionato, cifrato, public access bloccato
- [ ] `terraform test` e `static_contract.ps1` verdi
- [ ] Stack Entra applicato, admin consent concesso, credenziale confidenziale generata
- [ ] Piano AWS revisionato (nessun NAT Gateway, RDS single-AZ, node group mono-subnet)
- [ ] Apply base completato, output salvati in `~/.reverse-dr/`
- [ ] Utente `helios_app` creato, due secret Secrets Manager popolati
- [ ] Accesso `kubectl` funzionante, con il metodo scelto **dichiarato**
- [ ] 6 immagini in ECR con tag immutabile derivato dal commit
- [ ] External Secrets e ALB controller installati, ExternalSecret tutti `SecretSynced`
- [ ] Certificato ACM validato in `eu-south-1` e DNS puntato all'hostname ALB
- [ ] Overlay renderizzato senza `REPLACE_` e senza segreti, applicato
- [ ] Migrazioni applicate, inclusa `dr_telemetry`
- [ ] Lambda abilitata via digest con un secondo apply mirato
- [ ] Login OIDC completo, backup visibile su S3, `/api/v1/platform/status` non più `unknown`
- [ ] `contracts/deployment-contract.json` ancora coerente con quanto effettivamente
      deployato — se hai cambiato una porta, un health path o un nome, aggiornalo
