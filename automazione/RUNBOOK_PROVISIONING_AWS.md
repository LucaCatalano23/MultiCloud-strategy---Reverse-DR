# Runbook — provisioning manuale del sito primario AWS

Questa guida porta il **sito primario** della PoC Reverse DR da un account AWS vuoto a
Helios Desk funzionante su EKS, con RDS, ECR, EventBridge/SQS, Lambda e il CronJob di
backup che alimenta la metrica RPO della dashboard.

**Metodo: provisioning manuale dalla console AWS.** Terraform non viene eseguito. Lo stack
`infra/aws/` resta nel repository come **specifica dichiarativa** dell'architettura
target: ogni sezione di questa guida indica il modulo corrispondente, così i valori
costruiti a mano restano verificabili contro il codice.

**Regione: `eu-south-1` (Milano)** — regione *opt-in*, va abilitata prima di tutto (§1.3).

**Host di esecuzione:** WSL, repository clonato in `/path/to/repository`. I
comandi CLI di questa guida sono bash eseguibili da lì.

**Identità: fuori scope.** Le application registration Entra sono create e gestite dal team
identità aziendale. Questa guida ne *consuma* gli output (§2), non le crea.

---

## 0. Prima di iniziare: due conseguenze da mettere in conto

Non sono obiezioni alla scelta di procedere a mano — che è legittima e, con le
registrazioni Entra già gestite da altri, anche coerente. Sono due effetti concreti da
gestire, non da scoprire dopo.

**1. Il teardown diventa una checklist, non un comando.** Senza `terraform destroy`, ogni
risorsa va rimossa a mano nell'ordine giusto. Dimenticarne una significa continuare a
pagarla: i candidati tipici sono l'Elastic IP non associato, i log group CloudWatch, gli
snapshot RDS e l'ALB creato dal controller. Il §19 è la checklist ordinata — non è un
appendice opzionale.

**2. I test statici del repository non descrivono più ciò che è deployato.**
`architecture.tftest.hcl` e `static_contract.ps1` verificano il *codice* Terraform. Con il
provisioning manuale continuano a passare anche se la console diverge dall'architettura
dichiarata — AZ sbagliata, multi-AZ acceso, subnet in più. Restano utili come descrizione
formale del target, ma l'unica verifica reale diventa il §18. Vale la pena dirlo così in
tesi, invece di lasciar intendere che quei test coprano l'infrastruttura reale.

---

## 1. Prerequisiti

### 1.1 Toolchain WSL

Terraform **non serve più**. Serve invece tutto ciò che la console non può fare: build
delle immagini, accesso al cluster, installazione dei componenti Kubernetes.

```bash
sudo apt update
sudo apt install -y unzip curl git jq python3 openssl coreutils
```

| Tool | Perché | Nota |
|---|---|---|
| AWS CLI v2 | letture, ECR login, kubeconfig | installer ufficiale, non `apt install awscli` (è v1) |
| kubectl | overlay applicativo | versione compatibile con il cluster |
| helm `>= 3.12` | External Secrets Operator, AWS Load Balancer Controller | script `get-helm-3` |
| Docker | build delle 6 immagini | Docker Desktop con integrazione WSL abilitata, o engine nativo |
| jq | estrazione di valori nei comandi | `apt` |
| kubeconform | validazione dell'overlay (opzionale) | binario da GitHub |

Se usi Docker Desktop, abilita l'integrazione con la distribuzione in *Settings →
Resources → WSL Integration*: senza, `docker` esiste ma non trova il daemon.

### 1.2 Variabili di sessione

Esportale a ogni nuova shell — non persistono:

```bash
export AWS_REGION=eu-south-1
export AWS_DEFAULT_REGION=eu-south-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export PREFIX=reverse-dr-poc
export REPO_ROOT=/path/to/repository

if [ ! -d "$REPO_ROOT/automazione/apps" ]; then
  echo "ERRORE: $REPO_ROOT non contiene automazione/apps — correggi REPO_ROOT" >&2
else
  echo "account=$ACCOUNT_ID region=$AWS_REGION prefix=$PREFIX"
fi
```

`$PREFIX` è il contratto di naming del progetto (`project_name`-`environment`). Ogni
risorsa creata a mano deve rispettarlo: è ciò che rende riconoscibile cosa appartiene alla
PoC quando arriva il momento di smontarla.

### 1.3 Abilitare `eu-south-1` — passo obbligato

Milano è una regione **opt-in**: come tutte quelle lanciate dopo marzo 2019 nasce
disabilitata. Finché non è abilitata non compare nemmeno nel selettore di regione della
console.

Console: *Account* (menu in alto a destra) → **AWS Regions** → cerca *Europe (Milan)
eu-south-1* → **Enable**. L'abilitazione è asincrona e richiede qualche minuto.

Da CLI, per verificarne lo stato:

```bash
aws account get-region-opt-status --region-name eu-south-1
```

**In un account dentro una AWS Organization l'abilitazione può essere riservata al
management account.** Se ricevi `AccessDenied`, non è un limite del tuo
`AdministratorAccess`: è una decisione dell'organizzazione, va chiesta a chi la governa.

### 1.4 Disponibilità dei servizi a Milano

Milano non offre tutto ciò che offre l'Irlanda, e le famiglie di istanze variano per
regione. Verificalo adesso, non a metà provisioning:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=t3.medium,t4g.nano \
  --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output table

aws rds describe-orderable-db-instance-options \
  --engine postgres --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[0].EngineVersion' --output text

aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' --output table
```

La prima AZ dell'elenco sarà quella **primaria** (workload e dati), la seconda la
**witness** (nessun workload). Annotale: le userai in ogni sezione successiva.

Se `t4g.nano` non compare, la NAT instance ARM non è ordinabile: usa `t3.nano` **e**
un'AMI Amazon Linux 2023 **x86-64** invece di arm64 (§3.4). Cambiare istanza senza
cambiare architettura dell'AMI produce un'istanza che non si avvia, senza errori evidenti.

---

## 2. Input forniti dal team identità

Le due application registration esistono già, create dal team identità aziendale con la
naming convention interna:

| Applicazione | Ruolo nella PoC | Serve a |
|---|---|---|
| `demo-api-app-...` | resource server (API) | il suo **client ID** è l'audience degli access token |
| `demo-bff-app-...` | client web confidenziale | il BFF esegue Authorization Code + PKCE |

Valori da farsi consegnare prima del §16, perché entrano nel ConfigMap dell'applicazione:

| Valore | Dove finisce |
|---|---|
| Tenant ID | costruzione di issuer e endpoint |
| Client ID della **API** | `OIDC_AUDIENCE` — è il GUID, non `api://...` |
| Client ID del **BFF** | `OIDC_CLIENT_ID` |
| Issuer URL | `OIDC_ISSUER_URL` (`https://login.microsoftonline.com/<tenant>/v2.0`) |
| JWKS URL | `OIDC_JWKS_URL` |
| Authorization / token / end-session endpoint | omonime chiavi del ConfigMap |
| Scope delegato completo | `OIDC_SCOPES` (`openid profile email api://<api-client-id>/access_as_user`) |
| Nome del claim ruoli e valori ruolo | devono essere `roles` e `tickets.read` / `tickets.write` / `automation.execute` |

Due verifiche da chiedere esplicitamente al team identità, perché sono i punti in cui
questa integrazione si rompe in silenzio:

1. **Redirect URI esatto** registrato sul BFF: deve essere
   `https://<hostname>/api/v1/auth/callback`, con l'hostname del §3.1. Entra non accetta
   wildcard né path approssimati.
2. **Access token v2 e claim `roles`**: l'autorizzazione applicativa legge il claim `roles`
   dell'access token dell'API, non l'ID token del BFF. Se l'API emette token v1 l'audience
   cambia forma e la validazione fallisce.

> **Contratto condiviso col sito DR.** Il client ID della API è la stessa audience che il
> realm Keycloak DR deve emettere e validare (`infra/onprem/keycloak/realm/`). Ogni
> modifica va fatta sui due lati nello stesso cambiamento, altrimenti il failover rompe
> l'autorizzazione senza errori visibili ([`CLAUDE.md`](../CLAUDE.md) §5).

### 2.1 Il certificato al posto del client secret: `private_key_jwt`

Il team ha creato per il BFF una **credenziale a certificato**, perché la policy aziendale
vieta i client secret. Il BFF supporta questa modalità: lo scambio del code avviene con una
**client assertion** (`private_key_jwt`, RFC 7523) — un JWT firmato con la chiave privata,
inviato come `client_assertion` insieme a
`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`.

L'implementazione è in
`apps/backend/src/helios_bff/infrastructure/oidc_client_credentials.py`. Il selettore è la
variabile `OIDC_CLIENT_AUTH_METHOD`, già impostata a `private_key_jwt` nel ConfigMap del
primario; il sito DR resta su `client_secret`, perché il suo Keycloak è locale e non
soggetto alla policy del tenant. È configurazione per sito, non un branch nel codice.

Valori da farsi consegnare dal team identità, entrambi in **PEM**:

| Valore | Dove finisce |
|---|---|
| Chiave privata (PKCS#8) | `OIDC_CLIENT_PRIVATE_KEY` nel secret `.../application/config` |
| Certificato | `OIDC_CLIENT_CERTIFICATE` nello stesso secret |

Il certificato non è segreto, ma viaggia con la chiave perché serve a derivarne l'impronta
`x5t`: è così che Entra individua quale delle credenziali registrate sull'application ha
firmato l'assertion. L'impronta viene calcolata dal codice a partire dal certificato, non
configurata a mano — un'impronta copiata e disallineata dalla chiave produce un
`invalid_client` che non spiega la causa.

Se il team consegna un PKCS#12 (`.pfx`), estrai i due PEM senza lasciare la chiave in
chiaro su disco più del necessario:

```bash
umask 077
openssl pkcs12 -in <file.pfx> -nocerts -nodes -out /tmp/bff-key.pem
openssl pkcs12 -in <file.pfx> -clcerts -nokeys -out /tmp/bff-cert.pem
```

Entrambi i file vanno cancellati con `shred -u` subito dopo aver popolato il secret (§12.3).

---

## 3. Certificato ACM e hostname

Va richiesto per primo: la validazione DNS può richiedere tempo, e l'Ingress del §16 non
può essere creato senza l'ARN del certificato.

### 3.1 Scegliere l'hostname

```bash
export APP_HOST=<hostname-applicativo>     # es. helios.tuodominio.example
```

L'hostname deve essere HTTPS e stabile perché il BFF usa cookie `__Host-*`, che richiedono
`Secure`, path `/` e nessun attributo `Domain`. Un accesso via IP o via hostname ALB grezzo
in HTTP non degrada il login: lo rompe. È anche l'hostname che deve comparire nel redirect
URI registrato in Entra (§2).

### 3.2 Richiedere il certificato

Console → **Certificate Manager** (verifica in alto a destra di essere in *Europe (Milan)*)
→ **Request a certificate** → *Request a public certificate*.

| Campo | Valore |
|---|---|
| Fully qualified domain name | l'hostname scelto |
| Validation method | **DNS validation** |
| Key algorithm | RSA 2048 |

Il certificato dell'ALB deve stare in `eu-south-1`. `us-east-1` serve solo a CloudFront,
che questa PoC non usa come endpoint applicativo.

Dopo la richiesta, la console mostra un record `CNAME` di validazione: va creato nel DNS
che possiedi. Lo stato passa da *Pending validation* a **Issued**. Annota l'ARN:

```bash
export CERT_ARN=<arn-del-certificato>
```

Route 53 non è previsto da questa PoC: la zona DNS è ownership esterna, quindi il record va
creato dove il dominio è effettivamente delegato.

---

## 4. Rete

> Riferimento dichiarativo: `infra/aws/modules/network/`.

### 4.1 VPC

Console → **VPC** → *Your VPCs* → **Create VPC** → *VPC only*.

| Campo | Valore |
|---|---|
| Name tag | `reverse-dr-poc-vpc` |
| IPv4 CIDR | `10.42.0.0/16` |
| Tenancy | Default |

Dopo la creazione, *Actions → Edit VPC settings*: abilita **DNS resolution** e **DNS
hostnames**. Senza, la risoluzione dell'endpoint RDS dai pod non funziona.

### 4.2 Le quattro subnet

L'asimmetria è deliberata: la AZ primaria ospita workload e dati, la witness esiste solo
perché EKS pretende due subnet in AZ diverse e l'ALB pretende due subnet pubbliche. Le
subnet witness sono volutamente minime.

| Nome | AZ | CIDR | Tipo |
|---|---|---|---|
| `reverse-dr-poc-public-primary` | primaria | `10.42.0.0/24` | pubblica |
| `reverse-dr-poc-public-witness` | witness | `10.42.1.0/27` | pubblica |
| `reverse-dr-poc-private-primary` | primaria | `10.42.10.0/24` | privata |
| `reverse-dr-poc-private-witness` | witness | `10.42.11.0/28` | privata |

Sulle due subnet **pubbliche**: *Actions → Edit subnet settings* → **Enable auto-assign
public IPv4 address**.

**I tag non sono decorativi.** Il controller ALB scopre le subnet dove creare il load
balancer leggendo un tag: senza, l'Ingress resta senza indirizzo e l'errore nei log del
controller non è esplicito.

| Subnet | Tag obbligatori |
|---|---|
| entrambe le **pubbliche** | `kubernetes.io/role/elb` = `1` |
| `public-witness` | `Workloads` = `prohibited` |
| `private-primary` | `Workloads` = `allowed` |
| `private-witness` | `Workloads` = `prohibited` |

I tag `Workloads` sono documentali: dichiarano l'intenzione architetturale a chi legge la
console. Il tag `kubernetes.io/role/elb` è invece funzionale.

### 4.3 Internet Gateway e route table pubblica

1. **VPC → Internet gateways → Create**: nome `reverse-dr-poc-igw`, poi *Actions → Attach
   to VPC*.
2. **Route tables → Create**: nome `reverse-dr-poc-public`, VPC della PoC.
3. Nella route table: *Routes → Edit routes* → aggiungi `0.0.0.0/0` → target **Internet
   Gateway**.
4. *Subnet associations → Edit* → associa **entrambe** le subnet pubbliche.

### 4.4 NAT instance

La PoC usa una `t4g.nano` invece di un NAT Gateway: a basso traffico costa molto meno. È
una scelta dichiarata, con limiti altrettanto dichiarati (single point of failure, patching
a carico tuo, throughput limitato). Non è una baseline di produzione.

Prima il security group. **VPC → Security groups → Create**:

| Campo | Valore |
|---|---|
| Name | `reverse-dr-poc-nat` |
| VPC | quella della PoC |
| Inbound | Tipo *All traffic*, sorgente `10.42.10.0/24` (subnet privata primaria) |
| Outbound | Tipo *All traffic*, destinazione `0.0.0.0/0` |

L'inbound accetta **solo** la subnet privata primaria: è ciò che impedisce alla NAT di
diventare un proxy aperto.

Poi l'istanza. **EC2 → Instances → Launch an instance**:

| Campo | Valore |
|---|---|
| Name | `reverse-dr-poc-nat` |
| AMI | Amazon Linux 2023, architettura **arm64** |
| Instance type | `t4g.nano` |
| Key pair | **Proceed without a key pair** — nessun accesso SSH è previsto |
| VPC / Subnet | `reverse-dr-poc-public-primary` |
| Auto-assign public IP | Enable |
| Security group | `reverse-dr-poc-nat` (esistente) |
| Storage | 8 GiB, **gp3**, *Encrypted* |

In *Advanced details*:

| Campo | Valore |
|---|---|
| Metadata version | **V2 only (token required)** |
| Metadata response hop limit | `1` |

E in *User data*:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y iptables-services
cat >/etc/sysctl.d/90-nat.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system

default_interface="$(ip route show default | awk '{print $5; exit}')"
iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
iptables-save >/etc/sysconfig/iptables
systemctl enable --now iptables
```

Dopo l'avvio, il passo che si dimentica più spesso e che rende la NAT inutile senza alcun
errore visibile: selezionare l'istanza → *Actions → Networking →* **Change source/dest
check** → **Stop**. Una NAT instance con il controllo attivo scarta tutto il traffico che
non è destinato a sé stessa.

Infine l'Elastic IP. **EC2 → Elastic IPs → Allocate** → *Actions → Associate* → istanza
`reverse-dr-poc-nat`.

### 4.5 Route table privata

1. **Route tables → Create**: nome `reverse-dr-poc-private-primary`.
2. *Edit routes* → `0.0.0.0/0` → target **Instance** → `reverse-dr-poc-nat`.
3. *Subnet associations* → associa **solo** `reverse-dr-poc-private-primary`.

La subnet privata witness resta senza route verso internet: non deve ospitare workload, e
lasciarla senza egress è il modo più diretto per garantirlo.

---

## 5. Ruoli IAM per EKS

> Riferimento: `infra/aws/modules/eks/iam.tf`.

Console → **IAM → Roles → Create role**.

| Ruolo | Trusted entity | Policy gestite |
|---|---|---|
| `reverse-dr-poc-eks-cluster` | AWS service → **EKS** → *EKS - Cluster* | `AmazonEKSClusterPolicy` |
| `reverse-dr-poc-eks-node` | AWS service → **EC2** | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly` |

Il ruolo dei nodi **non** riceve `AmazonEKS_CNI_Policy`, che la console e molti tutorial
suggeriscono di aggiungere. Il CNI usa un ruolo IRSA dedicato (§6.4): dare i permessi di
rete al ruolo del nodo li estenderebbe a ogni pod che gira su quel nodo, che è esattamente
ciò che IRSA serve a evitare.

`AmazonEC2ContainerRegistryPullOnly` e non `ReadOnly`: i nodi devono scaricare immagini,
non elencare repository.

---

## 6. Cluster EKS

> Riferimento: `infra/aws/modules/eks/`.

### 6.1 Log group

Console → **CloudWatch → Log groups → Create**: nome `/aws/eks/reverse-dr-poc/cluster`,
retention **30 giorni**. Crearlo prima evita che EKS lo generi con retention infinita, che
è una voce di costo che cresce in silenzio.

### 6.2 Cluster

Console → **EKS → Add cluster → Create**.

| Campo | Valore |
|---|---|
| Name | `reverse-dr-poc` |
| Kubernetes version | default corrente AWS |
| Cluster service role | `reverse-dr-poc-eks-cluster` |
| Authentication mode | **EKS API** |
| Bootstrap cluster administrator access | **Disallow** |
| VPC | quella della PoC |
| Subnets | **entrambe le private** (primary e witness) |
| Cluster endpoint access | **Private** |
| Control plane logging | **API server**, **Audit**, **Authenticator** |

Due campi meritano attenzione:

- **Bootstrap administrator access = Disallow** significa che chi crea il cluster *non*
  diventa automaticamente amministratore. È deliberato — l'accesso è esplicito e
  tracciabile — ma comporta che subito dopo la creazione tu non possa usare `kubectl`
  finché non aggiungi l'access entry del §6.3.
- **Endpoint privato**: l'API server risponde solo da dentro la VPC. Vedi §11 per le
  opzioni di accesso.

La creazione richiede circa 10 minuti.

### 6.3 Access entry per il tuo ruolo

Cluster → tab **Access** → **Create access entry**.

Serve l'ARN del **ruolo**, non quello della sessione che restituisce
`get-caller-identity`. Per un ruolo SSO:

```bash
aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
  --query 'Roles[?starts_with(RoleName, `AWSReservedSSO_AdministratorAccess`)].Arn' --output text
```

| Campo | Valore |
|---|---|
| IAM principal ARN | l'ARN ottenuto sopra |
| Type | Standard |
| Access policy | `AmazonEKSClusterAdminPolicy`, scope **Cluster** |

### 6.4 OIDC provider e ruoli degli add-on

Cluster → tab **Overview** → copia l'**OpenID Connect provider URL**.

Console → **IAM → Identity providers → Add provider** → *OpenID Connect*:

| Campo | Valore |
|---|---|
| Provider URL | l'issuer del cluster |
| Audience | `sts.amazonaws.com` |

Poi due ruoli IRSA per gli add-on. Per entrambi: *Create role → Web identity*, provider
appena creato, audience `sts.amazonaws.com`; dopo la creazione **modifica la trust policy**
aggiungendo la condizione sul `sub`, che la console non permette di impostare in creazione:

| Ruolo | Policy | Condizione `sub` |
|---|---|---|
| `reverse-dr-poc-vpc-cni` | `AmazonEKS_CNI_Policy` | `system:serviceaccount:kube-system:aws-node` |
| `reverse-dr-poc-ebs-csi` | `AmazonEBSCSIDriverPolicy` | `system:serviceaccount:kube-system:ebs-csi-controller-sa` |

Trust policy attesa, con `<OIDC_HOST_PATH>` = issuer senza `https://`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC_HOST_PATH>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<OIDC_HOST_PATH>:aud": "sts.amazonaws.com",
        "<OIDC_HOST_PATH>:sub": "system:serviceaccount:kube-system:aws-node"
      }
    }
  }]
}
```

La condizione su `sub` è ciò che impedisce a *qualsiasi* service account del cluster di
assumere il ruolo. Senza, l'isolamento fra workload salta e IRSA diventa decorativo.

### 6.5 Node group

Cluster → tab **Compute** → **Add node group**.

| Campo | Valore |
|---|---|
| Name | `reverse-dr-poc-primary` |
| Node IAM role | `reverse-dr-poc-eks-node` |
| Kubernetes labels | `reverse-dr.io/failure-domain=primary-az`, `reverse-dr.io/workload-tier=application` |
| AMI type | Amazon Linux 2023 (x86-64) |
| Capacity type | On-Demand |
| Instance types | `t3.medium` |
| Disk size | 30 GiB |
| Min / Desired / Max | 1 / 1 / 2 |
| Subnets | **solo** `reverse-dr-poc-private-primary` |

La singola subnet è il cuore della scelta architetturale: i pod stanno tutti nella AZ
primaria. La label `failure-domain` non è documentale — il CronJob di backup la usa come
`nodeSelector`.

### 6.6 Add-on

Cluster → tab **Add-ons** → **Get more add-ons**. Installa nell'ordine:

| Add-on | IAM role |
|---|---|
| Amazon VPC CNI | `reverse-dr-poc-vpc-cni` |
| kube-proxy | — |
| CoreDNS | — |
| Amazon EBS CSI Driver | `reverse-dr-poc-ebs-csi` |

CoreDNS resta in stato *Degraded* finché il node group non ha nodi pronti: è atteso, non un
errore.

---

## 7. ECR

> Riferimento: `infra/aws/modules/ecr/`.

Console → **ECR → Repositories → Create repository**, cinque volte:

`reverse-dr-poc-frontend`, `reverse-dr-poc-bff`, `reverse-dr-poc-ticket`,
`reverse-dr-poc-automation`, `reverse-dr-poc-ticket-processor`.

Per ciascuno:

| Campo | Valore |
|---|---|
| Visibility | Private |
| Tag immutability | **Immutable** |
| Scan on push | Enabled |
| Encryption | AES-256 |

`ticket-processor` non è un quinto microservizio: è l'immagine della function, condivisa
fra il sito primario (AWS Lambda) e il sito DR (stesso runtime sotto `lambda-dr`). Ha un
repository proprio perché il suo ciclo di vita è quello della function.

Su ogni repository, *Lifecycle policy → Create rule*: due regole, rimuovere le untagged
dopo 7 giorni e mantenere le ultime 20 immagini. È una retention da PoC, non una policy di
compliance.

---

## 8. RDS PostgreSQL

> Riferimento: `infra/aws/modules/database/`.

### 8.1 Security group e subnet group

**VPC → Security groups → Create**: nome `reverse-dr-poc-postgres`, nessuna regola per
ora — la aggiungi al §8.3, quando esisterà il security group del cluster.

**RDS → Subnet groups → Create**: nome `reverse-dr-poc-postgres`, VPC della PoC, entrambe
le subnet **private**. RDS pretende due AZ anche per un'istanza single-AZ: è il motivo per
cui la subnet witness esiste.

### 8.2 Istanza

Console → **RDS → Create database** → *Standard create* → **PostgreSQL**.

| Campo | Valore |
|---|---|
| Engine version | 16.x |
| Templates | Dev/Test |
| Availability | **Single DB instance** |
| DB instance identifier | `reverse-dr-poc-postgres` |
| Master username | `platform_admin` |
| Credentials management | **Managed in AWS Secrets Manager** |
| Instance class | `db.t4g.micro` |
| Storage | gp3, 20 GiB, autoscaling max **100 GiB** |
| Encryption | Enabled |
| VPC / subnet group | quella della PoC / `reverse-dr-poc-postgres` |
| Public access | **No** |
| Security group | `reverse-dr-poc-postgres` |
| Availability zone | la **primaria** |
| IAM database authentication | Enabled |
| Initial database name | `helios` |
| Backup retention | 7 giorni, finestra `01:00-02:00` UTC |
| Maintenance window | `sun:03:00-sun:04:00` UTC |
| Log exports | `postgresql`, `upgrade` |
| Performance Insights | **Disabled** |
| Enhanced monitoring | **Disabled** |
| Extended support | **Disabled** |

*Multi-AZ disabilitato e AZ fissata sulla primaria non sono una svista*: il database
condivide deliberatamente il failure domain dei workload. È il guasto che il drill di DR
simula.

Performance Insights ed Enhanced Monitoring sono disattivati per costo. Extended support
va disattivato esplicitamente, altrimenti genera addebiti quando la major esce dal
supporto standard.

La creazione richiede circa 8 minuti.

### 8.3 Regola di ingresso

Quando il cluster EKS esiste, recupera il suo security group:

```bash
aws eks describe-cluster --name "$PREFIX" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
```

Poi su `reverse-dr-poc-postgres` → *Inbound rules → Edit*:

| Campo | Valore |
|---|---|
| Type | PostgreSQL (5432) |
| Source | il security group del cluster |

Sorgente un security group e non un CIDR: se le subnet cambiassero, la regola resterebbe
corretta. Ed è ciò che rende RDS irraggiungibile da fuori dal cluster — inclusa la tua
shell, motivo per cui il bootstrap del §12 gira in un pod.

---

## 9. S3

> Riferimento: `infra/aws/modules/storage_edge/`.

Due bucket. I nomi devono essere globalmente unici: includi account e regione.

| Bucket | Nome | Contenuto |
|---|---|---|
| Backup | `reverse-dr-poc-backup-<ACCOUNT_ID>-eu-south-1` | dump PostgreSQL consumati dal sito DR |
| Frontend | `reverse-dr-poc-frontend-<ACCOUNT_ID>-eu-south-1` | build React per preview statica |

Per entrambi: **Block all public access** attivo, **Bucket Versioning** abilitato,
**server-side encryption** SSE-S3.

Sul bucket di backup, *Management → Lifecycle rules → Create*: transizione a **Glacier
Instant Retrieval** dopo 30 giorni, scadenza dopo 365.

> **Il bucket di backup è l'artefatto più importante di tutta la PoC.** È l'unica cosa che
> il sito DR può ripristinare quando il primario non esiste più. Se un guardrail
> dell'organizzazione cancella bucket non conformi, verificalo qui prima di andare avanti.

---

## 10. Secrets Manager

> Riferimento: `infra/aws/modules/database/` (contenitori) — i valori non sono mai in
> Terraform né in questa guida.

Console → **Secrets Manager → Store a new secret** → *Other type of secret*, due volte.

| Nome | Chiavi | Chi lo legge |
|---|---|---|
| `reverse-dr-poc/application/database` | `DATABASE_URL` | BFF, ticket, automation, CronJob backup |
| `reverse-dr-poc/application/config` | `OIDC_CLIENT_PRIVATE_KEY`, `OIDC_CLIENT_CERTIFICATE`, `SESSION_ENCRYPTION_KEY` | solo BFF |

Creali ora **vuoti o con valori segnaposto**: i valori reali arrivano al §12, quando
esisterà l'utente PostgreSQL applicativo. Imposta *Recovery window* a 7 giorni.

Il secret master di RDS, creato automaticamente al §8, è separato e **nessun ruolo
applicativo deve poterlo leggere**: contiene le credenziali di `platform_admin`, che a
runtime non vanno mai usate.

---

## 11. Ruoli IRSA dei workload

> Riferimento: `infra/aws/modules/workload_identity/`.

Quattro ruoli, uno per workload. È la parte più delicata del provisioning manuale: un
errore nella condizione `sub` non produce un errore in fase di creazione, ma un
`SecretSyncError` opaco settimane dopo.

| Ruolo IAM | Service account (`helios-desk`) | Permessi |
|---|---|---|
| `reverse-dr-poc-bff` | `helios-bff` | lettura dei due secret applicativi |
| `reverse-dr-poc-ticket` | `helios-ticket-service` | lettura secret + `events:PutEvents` sul solo bus applicativo |
| `reverse-dr-poc-automation` | `helios-automation-service` | lettura secret + consumo della coda + invoke della Lambda |
| `reverse-dr-poc-backup` | `helios-postgres-backup` | lettura secret DB + read/write sul solo prefisso `postgres/` del bucket backup |

Per ciascuno: *IAM → Roles → Create role → Web identity*, provider OIDC del cluster,
audience `sts.amazonaws.com`. Poi sostituisci la trust policy con:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC_HOST_PATH>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<OIDC_HOST_PATH>:aud": "sts.amazonaws.com",
        "<OIDC_HOST_PATH>:sub": "system:serviceaccount:helios-desk:<SERVICE_ACCOUNT>"
      }
    }
  }]
}
```

Policy inline, una per ruolo. BFF:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"],
    "Resource": [
      "arn:aws:secretsmanager:eu-south-1:<ACCOUNT_ID>:secret:reverse-dr-poc/application/database-*",
      "arn:aws:secretsmanager:eu-south-1:<ACCOUNT_ID>:secret:reverse-dr-poc/application/config-*"
    ]
  }]
}
```

Il suffisso `-*` è obbligatorio: Secrets Manager aggiunge sei caratteri casuali all'ARN, e
una policy senza wildcard non corrisponde a nulla.

Backup — nota il prefisso, che è ciò che impedisce al job di toccare il resto del bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:eu-south-1:<ACCOUNT_ID>:secret:reverse-dr-poc/application/database-*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::<BACKUP_BUCKET>/postgres/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<BACKUP_BUCKET>",
      "Condition": { "StringLike": { "s3:prefix": "postgres/*" } }
    }
  ]
}
```

Ticket aggiunge `events:PutEvents` sull'ARN del bus (§13). Automation aggiunge
`sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` sulla coda e
`lambda:InvokeFunction` sulla function (§14).

---

## 12. Accesso al cluster, bootstrap del database e dei segreti

### 12.1 kubeconfig

```bash
aws eks update-kubeconfig --name "$PREFIX"
kubectl get nodes
```

Se va in timeout, l'endpoint è privato (§6.2) e l'API server risponde solo da dentro la
VPC. Tre opzioni:

| Opzione | Costo | Nota |
|---|---|---|
| Bastion EC2 nella subnet pubblica + SSM Session Manager port forwarding | basso, temporaneo | non richiede SSH né chiavi; consigliata |
| Client VPN | alto (orario per endpoint e per connessione) | sovradimensionata per una PoC |
| Endpoint pubblico limitato al tuo `/32` | zero | pragmatica, ma espone l'API server |

Per la terza: cluster → *Networking → Manage endpoint access* → Public and private, con
`Advanced settings` limitato al tuo IP.

```bash
curl -s https://checkip.amazonaws.com
```

Da WSL l'IP è quello della connessione Windows sottostante e su rete aziendale cambia con
il gateway di uscita: un `/32` che oggi funziona domani può non funzionare più. È un
argomento a favore del bastion. Qualunque opzione scegli, dichiarala in tesi invece di
subirla.

### 12.2 Utente PostgreSQL applicativo

L'utente master non va usato dai workload. RDS è raggiungibile solo dal cluster, quindi la
creazione avviene in un pod effimero.

```bash
umask 077
MASTER_SECRET_ARN=$(aws secretsmanager list-secrets \
  --filters Key=name,Values=rds  --query "SecretList[?contains(Name,'${PREFIX}-postgres')].ARN | [0]" --output text)
MASTER_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ARN" \
  --query SecretString --output text | jq -r .password)

RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DB_NAME=helios
APP_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)

MASTER_URL="postgresql://platform_admin:$(printf '%s' "$MASTER_PASSWORD" | jq -sRr @uri)@${RDS_HOST}/${DB_NAME}?sslmode=require"
```

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

`CREATE` su `public` serve perché le migrazioni (§17) girano con questo utente.

### 12.3 Valori dei due secret

```bash
umask 077
jq -n --arg url "postgresql+asyncpg://helios_app:${APP_PASSWORD}@${RDS_HOST}/${DB_NAME}?ssl=require" \
  '{DATABASE_URL:$url}' > /tmp/db-secret.json

# La chiave privata e il certificato del BFF arrivano dal team identita' (§2.1).
jq -n \
  --arg key "$(openssl rand -base64 48)" \
  --rawfile private_key /tmp/bff-key.pem \
  --rawfile certificate /tmp/bff-cert.pem \
  '{OIDC_CLIENT_PRIVATE_KEY:$private_key, OIDC_CLIENT_CERTIFICATE:$certificate, SESSION_ENCRYPTION_KEY:$key}' \
  > /tmp/config-secret.json

aws secretsmanager put-secret-value --secret-id "${PREFIX}/application/database" --secret-string file:///tmp/db-secret.json
aws secretsmanager put-secret-value --secret-id "${PREFIX}/application/config"   --secret-string file:///tmp/config-secret.json

shred -u /tmp/db-secret.json /tmp/config-secret.json /tmp/bff-key.pem /tmp/bff-cert.pem
unset APP_PASSWORD
```

`--rawfile` invece di `--arg`: preserva i newline del PEM, che sono significativi. Un PEM
appiattito su una riga non è caricabile e produce `client certificate is not valid PEM`
all'avvio del BFF.

Lo schema `postgresql+asyncpg://` è quello atteso da SQLAlchemy async; il CronJob di backup
lo riscrive in memoria a `postgresql://` prima di `pg_dump`.

`OIDC_CLIENT_SECRET` resta un segnaposto: vedi §2.1: con la credenziale a certificato il
login non si completa finché il BFF non implementa la client assertion.

> **Limite dichiarato:** la rotazione di questi secret non è automatizzata. Va gestita a
> mano, o dichiarata come limite in tesi.

---

## 13. EventBridge e SQS

> Riferimento: `infra/aws/modules/automation/`.

**SQS → Create queue**, due volte, tipo *Standard*:

| Coda | Parametri |
|---|---|
| `reverse-dr-poc-ticket-automation-dlq` | message retention **14 giorni** (1209600 s) |
| `reverse-dr-poc-ticket-automation` | visibility timeout **180 s**, retention **4 giorni** (345600 s), *Dead-letter queue* = la DLQ con **Maximum receives = 5** |

Il visibility timeout deve restare almeno pari al timeout della Lambda (30 s) moltiplicato
per i tentativi: 180 s lascia margine. Un valore troppo basso produce elaborazioni
duplicate difficili da diagnosticare.

**EventBridge → Event buses → Create**: nome `reverse-dr-poc-application`. Poi
*Archives → Create*: nome `reverse-dr-poc-application`, retention **7 giorni**.

**EventBridge → Rules → Create rule**: nome `reverse-dr-poc-ticket-automation`, event bus
quello appena creato, target la coda `reverse-dr-poc-ticket-automation`. Il pattern deve
corrispondere agli eventi emessi dal ticket service — verificalo in
`modules/automation/main.tf`, dove è definito in modo autoritativo.

---

## 14. Immagini container e Lambda

### 14.1 Login e tag

```bash
cd "$REPO_ROOT"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
export TAG=$(git rev-parse --short HEAD)
export BACKUP_TAG="backup-${TAG}"
BACKEND="automazione/apps/backend"
```

I repository sono immutabili: un tag pubblicato non si sovrascrive. Mai `latest`.

### 14.2 I quattro servizi

Il contesto di build del backend è `apps/backend`, non la directory del singolo servizio:
i servizi condividono `src/` e `requirements.txt`.

```bash
docker build -t "$REGISTRY/${PREFIX}-bff:$TAG"        -f "$BACKEND/services/bff/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/${PREFIX}-ticket:$TAG"     -f "$BACKEND/services/ticket-service/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/${PREFIX}-automation:$TAG" -f "$BACKEND/services/automation-service/Dockerfile" "$BACKEND"
docker build -t "$REGISTRY/${PREFIX}-frontend:$TAG"   automazione/apps/frontend

for repo in bff ticket automation frontend; do
  docker push "$REGISTRY/${PREFIX}-$repo:$TAG"
done
```

I nodi sono `t3.medium`, quindi x86-64: se costruisci da WSL su Windows ARM aggiungi
`--platform linux/amd64`, altrimenti i pod falliscono con `exec format error`.

Il frontend non richiede variabili di build: `runtime-config.json` è generato all'avvio del
container, così la stessa immagine gira identica su AWS e on-prem.

### 14.3 La function

Il Dockerfile fa `COPY automazione/apps/functions/...`: il contesto è la root del
repository.

```bash
docker build -t "$REGISTRY/${PREFIX}-ticket-processor:$TAG" \
  -f automazione/apps/functions/ticket-processor/Dockerfile .
docker push "$REGISTRY/${PREFIX}-ticket-processor:$TAG"
```

### 14.4 L'immagine di backup — da costruire, non esiste nel repo

Il CronJob referenzia un'immagine che il repository non contiene. Serve `pg_dump` **e**
`psql` (per scrivere la metrica RPO), AWS CLI v2, `sed`, `sha256sum`.

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

docker build -t "$REGISTRY/${PREFIX}-automation:$BACKUP_TAG" \
  -f automazione/apps/backup/Dockerfile automazione/apps/backup
docker push "$REGISTRY/${PREFIX}-automation:$BACKUP_TAG"
```

La major di `pg_dump` deve essere `>=` a quella del server RDS: se aggiorni RDS, aggiorna
anche questa immagine.

### 14.5 Ruolo e function Lambda

**IAM → Roles → Create role** → *AWS service → Lambda*: nome
`reverse-dr-poc-ticket-automation-lambda`, con `AWSLambdaBasicExecutionRole` e una policy
inline che consenta la lettura dei due secret applicativi.

**CloudWatch → Log groups → Create**:
`/aws/lambda/reverse-dr-poc-ticket-automation`, retention 30 giorni.

**Lambda → Create function** → *Container image*:

| Campo | Valore |
|---|---|
| Function name | `reverse-dr-poc-ticket-automation` |
| Container image URI | **il digest**, non il tag (sotto) |
| Architecture | x86_64 |
| Execution role | `reverse-dr-poc-ticket-automation-lambda` |
| Memory | 256 MB |
| Timeout | 30 s |
| Reserved concurrency | 2 |

```bash
aws ecr describe-images --repository-name "${PREFIX}-ticket-processor" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text
```

Il digest e non il tag: Lambda risolve il tag una sola volta alla creazione, quindi un tag
dà una falsa immutabilità.

Poi *Configuration → Triggers → Add trigger* → **SQS** → coda
`reverse-dr-poc-ticket-automation`, batch size **10**, batch window **5 s**.

---

## 15. Componenti di piattaforma Kubernetes

### 15.1 External Secrets Operator

I CRD devono esistere prima dell'overlay, altrimenti l'apply fallisce a metà.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  -f "$REPO_ROOT/automazione/infra/aws/kubernetes/external-secrets-values.yaml.example"

kubectl -n external-secrets rollout status deploy/external-secrets
```

### 15.2 AWS Load Balancer Controller

Serve un ruolo IRSA `reverse-dr-poc-aws-load-balancer-controller`, con la stessa struttura
di trust policy del §11 ma `sub` =
`system:serviceaccount:kube-system:aws-load-balancer-controller`. La policy dei permessi è
in `infra/aws/modules/eks/policies/aws-load-balancer-controller-v3.4.2.json.tftpl`: usa
quel documento, che è la versione ridotta e verificata della policy ufficiale.

```bash
K8S_DIR="$REPO_ROOT/automazione/infra/aws/kubernetes"
WORK=~/.reverse-dr/render && mkdir -p "$WORK"

LBC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-aws-load-balancer-controller"
VPC_ID=$(aws eks describe-cluster --name "$PREFIX" --query 'cluster.resourcesVpcConfig.vpcId' --output text)

sed "s|REPLACE_LOAD_BALANCER_CONTROLLER_ROLE_ARN|${LBC_ROLE_ARN}|" \
  "$K8S_DIR/aws-load-balancer-controller-serviceaccount.yaml" > "$WORK/alb-sa.yaml"
kubectl -n kube-system apply -f "$WORK/alb-sa.yaml"

sed -e "s|REPLACE_VPC_ID|${VPC_ID}|" \
    -e "s|^clusterName:.*|clusterName: ${PREFIX}|" \
    -e "s|^region:.*|region: ${AWS_REGION}|" \
  "$K8S_DIR/aws-load-balancer-controller-values.yaml.example" > "$WORK/alb-values.yaml"

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system -f "$WORK/alb-values.yaml"

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

Installare una versione del chart più recente senza verificare il delta di permessi produce
un `AccessDenied` nei log e un Ingress che resta senza indirizzo.

---

## 16. Overlay applicativo

I manifest in `infra/aws/kubernetes/` sono template con placeholder `REPLACE_*` e non vanno
applicati direttamente. Si lavora su una copia fuori dal repository.

```bash
OVERLAY=~/.reverse-dr/overlay && rm -rf "$OVERLAY" && mkdir -p "$OVERLAY"
cp "$K8S_DIR"/*.yaml "$OVERLAY/"
rm -f "$OVERLAY/aws-load-balancer-controller-serviceaccount.yaml"

BACKUP_BUCKET=<nome-bucket-backup>
LAMBDA_NAME="${PREFIX}-ticket-automation"

sed -i \
  -e "s|REPLACE_AWS_REGION|${AWS_REGION}|g" \
  -e "s|REPLACE_FRONTEND_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-frontend|g" \
  -e "s|REPLACE_BFF_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-bff|g" \
  -e "s|REPLACE_TICKET_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-ticket|g" \
  -e "s|REPLACE_AUTOMATION_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-automation|g" \
  -e "s|REPLACE_BACKUP_IMAGE_TAG|${BACKUP_TAG}|g" \
  -e "s|REPLACE_IMAGE_TAG|${TAG}|g" \
  -e "s|REPLACE_BFF_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-bff|g" \
  -e "s|REPLACE_TICKET_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-ticket|g" \
  -e "s|REPLACE_AUTOMATION_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-automation|g" \
  -e "s|REPLACE_BACKUP_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-backup|g" \
  -e "s|REPLACE_APPLICATION_DATABASE_SECRET_ARN|${PREFIX}/application/database|g" \
  -e "s|REPLACE_APPLICATION_CONFIG_SECRET_ARN|${PREFIX}/application/config|g" \
  -e "s|REPLACE_BACKUP_BUCKET_NAME|${BACKUP_BUCKET}|g" \
  -e "s|REPLACE_AUTOMATION_LAMBDA_FUNCTION_NAME|${LAMBDA_NAME}|g" \
  -e "s|REPLACE_ACM_CERTIFICATE_ARN|${CERT_ARN}|g" \
  -e "s|REPLACE_APP_HOSTNAME|${APP_HOST}|g" \
  "$OVERLAY"/*.yaml
```

Restano i placeholder `REPLACE_ENTRA_*`, che vanno sostituiti con i valori del §2. Sono
otto: issuer, JWKS, audience (client ID della API), client ID del BFF, scope, e i tre
endpoint OIDC. Sostituiscili esplicitamente, senza indovinare — un endpoint sbagliato
produce un fallimento di login che assomiglia a un problema di rete.

```bash
cd "$OVERLAY"
grep -rn "REPLACE_" . && echo "PLACEHOLDER RESIDUI — fermati qui" || echo "nessun placeholder residuo"
kubectl kustomize . > rendered.yaml
kubeconform -strict -summary -ignore-missing-schemas rendered.yaml
grep -inE "password|secret_key|BEGIN (RSA|EC|PRIVATE)" rendered.yaml
```

L'ultimo `grep` non deve trovare nulla: il render contiene solo ARN e riferimenti a
`ExternalSecret`. Se ci trovi un valore segreto, il flusso dei segreti è stato aggirato.

```bash
kubectl apply -f "$OVERLAY/rendered.yaml"
kubectl -n helios-desk get externalsecret
kubectl -n helios-desk get pods -w
```

Se un `ExternalSecret` resta in `SecretSyncError`, l'ordine di debug è: annotazione IRSA sul
service account → condizione `sub` della trust policy → chiavi presenti nel secret AWS.

```bash
kubectl -n helios-desk describe externalsecret helios-bff-database | tail -20
```

I pod resteranno in `CrashLoopBackOff` finché le tabelle non esistono: il §17 è il passo
mancante, non un errore.

---

## 17. Schema del database

Le immagini dei servizi **non** eseguono migrazioni all'avvio: nessun initContainer, nessun
entrypoint di migrazione. È deliberato — lo schema non va modificato da N repliche in
parallelo — e implica che vada applicato esplicitamente.

Quattro migrazioni, in quest'ordine:

```
apps/backend/services/ticket-service/migrations/001_initial.sql
apps/backend/services/bff/migrations/001_initial.sql
apps/backend/services/bff/migrations/002_dr_telemetry.sql
apps/backend/services/automation-service/migrations/001_initial.sql
```

`infra/onprem/scripts/apply-migrations.sh` implementa questa sequenza (ConfigMap + Job
`psql`), ma ha `DB_SECRET` hardcoded a `helios-app-database`, il nome materializzato
on-prem; su AWS External Secrets produce un Secret per workload. Rendi la variabile
sovrascrivibile (`DB_SECRET="${DB_SECRET:-helios-app-database}"`) e invocalo con
`DB_SECRET=helios-bff-database`, oppure replica il Job a mano.

Le migrazioni usano `CREATE TABLE IF NOT EXISTS`: sono idempotenti.

`002_dr_telemetry.sql` non è opzionale. Crea la tabella `dr_telemetry` in cui il CronJob di
backup scrive `backup.last_success` e il playbook di failover scrive
`failover.last_promotion`. Senza, la dashboard mostra `unknown` per RPO e RTO — che è
l'esito onesto di "mai misurato", non un bug da mascherare con un default numerico.

```bash
kubectl -n helios-desk rollout restart deploy/helios-bff deploy/helios-ticket-service deploy/helios-automation-service
kubectl -n helios-desk rollout status deploy/helios-bff
```

---

## 18. DNS finale e verifica end-to-end

L'ALB esiste solo dopo l'apply dell'Ingress. Ora ha un hostname:

```bash
kubectl -n helios-desk get ingress helios-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Crea il record `CNAME` da `$APP_HOST` verso quel valore, nel DNS dove il dominio è
delegato.

Poi, nell'ordine — ogni passo dipende dal precedente:

```bash
# 1. Pod sani
kubectl -n helios-desk get pods
kubectl -n helios-desk exec deploy/helios-bff -- wget -qO- http://127.0.0.1:8000/health/ready
```

```bash
# 2. Target ALB sani
for TG in $(aws elbv2 describe-target-groups \
      --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-heliosde')].TargetGroupArn" \
      --output text); do
  echo "== $TG"
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
done
```

```bash
# 3. Frontend e API via HTTPS sull'hostname reale
curl -sSf "https://${APP_HOST}/healthz" && echo OK
curl -sS -o /dev/null -w '%{http_code}\n' "https://${APP_HOST}/api/v1/platform/status"
```

```bash
# 4. Backup: attendi un ciclo del CronJob (max 10 minuti)
kubectl -n helios-desk get cronjob helios-postgres-backup
aws s3 ls "s3://${BACKUP_BUCKET}/postgres/"
```

```bash
# 5. Telemetria RPO
curl -sS "https://${APP_HOST}/api/v1/platform/status" | jq
```

Il punto 5 chiude il cerchio con la tesi: `backup.last_success` viene scritta in
`dr_telemetry` **dopo** l'upload su S3, non dopo il dump. Se è valorizzata, il backup è
davvero su S3 e davvero ripristinabile dal sito DR.

```bash
# 6. Login OIDC completo dal browser, su https://$APP_HOST
```

Il login usa `private_key_jwt` (§2.1). I criteri di verifica sono due: che si arrivi alla
dashboard, e che i cookie di sessione si chiamino `__Host-*` con `Secure` e `SameSite` — un
cookie senza il prefisso `__Host-` significa che qualcosa ha spostato il traffico fuori
dall'origine canonica.

Se il login fallisce con `invalid_client`, l'ordine di debug è: `OIDC_CLIENT_AUTH_METHOD`
effettivamente a `private_key_jwt` nel ConfigMap → chiave e certificato che appartengono
alla stessa coppia (l'`x5t` derivato dal certificato deve corrispondere alla credenziale
registrata sull'application) → `OIDC_TOKEN_ENDPOINT` esatto, perché finisce nel claim `aud`
dell'assertion e Entra lo valida.

```bash
kubectl -n helios-desk logs deploy/helios-bff --tail=50
```

### Verifica dell'architettura dichiarata

Con il provisioning manuale nulla garantisce che la console corrisponda all'architettura
del §0. Questi controlli lo verificano:

```bash
aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
  --query 'DBInstances[0].[MultiAZ,AvailabilityZone,PubliclyAccessible]' --output text
# atteso: False  <az-primaria>  False

aws eks describe-nodegroup --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" \
  --query 'nodegroup.subnets' --output text
# atteso: una sola subnet

aws ec2 describe-instances --filters "Name=tag:Name,Values=${PREFIX}-nat" \
  --query 'Reservations[].Instances[].SourceDestCheck' --output text
# atteso: False

aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`]' --output text
# atteso: vuoto
```

---

## 19. Teardown manuale

Senza `terraform destroy` l'ordine conta, e ogni risorsa dimenticata continua a costare.
Segui questa sequenza.

```bash
# 1. Salva i backup: sono l'unico artefatto che il sito DR puo' ripristinare.
mkdir -p ~/.reverse-dr/backup-archive
aws s3 sync "s3://${BACKUP_BUCKET}/postgres/" ~/.reverse-dr/backup-archive/

# 2. L'ALB non e' una risorsa che hai creato tu: lo cancella il controller
#    quando sparisce l'Ingress. Se salti questo passo, la VPC non si cancella
#    perche' restano ENI orfane.
kubectl -n helios-desk delete ingress helios-public
sleep 90
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
# deve essere vuoto prima di proseguire
```

Poi, da console, in quest'ordine:

| # | Risorsa | Nota |
|---|---|---|
| 3 | Node group EKS | ~5 minuti |
| 4 | Cluster EKS | ~10 minuti |
| 5 | Istanza RDS | scegli se conservare lo snapshot finale |
| 6 | Subnet group RDS | dopo l'istanza |
| 7 | Lambda + event source mapping | |
| 8 | Code SQS (2) | |
| 9 | Regola, archive e bus EventBridge | l'archive va rimosso prima del bus |
| 10 | Repository ECR (5) | vanno svuotati o cancellati con le immagini |
| 11 | Bucket S3 (2) | svuotali prima; il versioning richiede di rimuovere anche le versioni |
| 12 | Secret Secrets Manager (2 + master RDS) | restano recuperabili 7 giorni |
| 13 | **Elastic IP** | *disassociare non basta*: un EIP allocato e non associato si paga |
| 14 | Istanza NAT | |
| 15 | Ruoli IAM (2 EKS + 2 add-on + 4 IRSA + 1 ALB + 1 Lambda) | 10 ruoli |
| 16 | OIDC identity provider | |
| 17 | Route table, subnet, IGW, VPC | in quest'ordine |
| 18 | **Log group CloudWatch** | EKS, Lambda e VPC restano a pagamento se dimenticati |
| 19 | Certificato ACM | gratuito, ma lascia sporco l'account |

Verifica finale che non sia rimasto nulla con il prefisso della PoC:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Name,Values="${PREFIX}*" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

Non tutte le risorse sono taggate — è il limite del provisioning manuale — quindi
controlla anche la fattura dei giorni successivi.

---

## 20. Checklist

**Prerequisiti**
- [ ] `eu-south-1` abilitata; `t3.medium`, `t4g.nano`, `db.t4g.micro` disponibili
- [ ] Valori Entra ricevuti dal team identità (§2)
- [ ] Deciso come gestire il blocco della credenziale a certificato (§2.1)
- [ ] Certificato ACM **Issued** in `eu-south-1`

**Infrastruttura**
- [ ] VPC, 4 subnet con i tag corretti, IGW, 2 route table
- [ ] NAT instance con **source/dest check disabilitato** e EIP associato
- [ ] Cluster EKS, access entry, OIDC provider, 4 add-on
- [ ] Node group su **una sola** subnet, con le due label
- [ ] 5 repository ECR immutabili
- [ ] RDS single-AZ non pubblico, SG che accetta solo il SG del cluster
- [ ] 2 bucket S3 privati e versionati, lifecycle sul backup
- [ ] 2 secret Secrets Manager
- [ ] 4 ruoli IRSA con condizione `sub` corretta
- [ ] Bus, archive, regola EventBridge, 2 code SQS
- [ ] Lambda da **digest** con trigger SQS

**Applicazione**
- [ ] 6 immagini pubblicate con tag derivato dal commit
- [ ] Utente `helios_app` creato, secret popolati
- [ ] External Secrets e ALB controller in esecuzione
- [ ] Overlay senza `REPLACE_` residui e senza segreti, applicato
- [ ] Migrazioni applicate, inclusa `dr_telemetry`
- [ ] DNS puntato all'hostname ALB

**Verifica**
- [ ] Health check verdi, target ALB sani
- [ ] Backup visibile su S3 e `platform/status` non più `unknown`
- [ ] I quattro controlli architetturali del §18 danno i valori attesi
- [ ] `contracts/deployment-contract.json` coerente con quanto deployato
