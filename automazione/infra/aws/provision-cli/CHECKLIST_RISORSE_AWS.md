# Checklist di verifica e ripristino manuale delle risorse AWS

Questa checklist copre le risorse create o configurate da `provision.sh`,
raggruppate per servizio e dipendenza. Per ogni voce indica cosa controllare
nella AWS Management Console e come ricreare o riparare manualmente la risorsa.

Riferimenti locali:

- [`provision.sh`](./provision.sh), sorgente autorevole per nomi e parametri;
- [`RUNBOOK_PROVISIONING_AWS.md`](../../../RUNBOOK_PROVISIONING_AWS.md), motivazioni architetturali;
- [`kubernetes/`](../kubernetes/), manifest applicativi e valori Helm.

## 0. Contesto da fissare prima dei controlli

- [ ] Account AWS corretto: annotare `<ACCOUNT_ID>` dalla barra della Console.
- [ ] Regione selezionata: `eu-south-1` (Milano), salvo override di `AWS_REGION`.
- [ ] Prefisso: `reverse-dr-poc`, salvo override di `PREFIX`.
- [ ] Tag attesi dove applicati:
  - `Name=<nome risorsa>`;
  - `Project=reverse-dr`;
  - `Environment=poc`.
- [ ] Availability Zone primaria e witness coincidono con `PRIMARY_AZ` e
  `WITNESS_AZ` presenti in `~/.reverse-dr/state.env`.
- [ ] Non è presente un NAT Gateway: l'architettura usa deliberatamente una NAT
  instance EC2.

> Non copiare valori segreti, password o chiavi private in ticket, screenshot o
> documentazione. Per i secret verificare nomi e metadati; mostrare il valore
> solo quando indispensabile.

## 1. ACM — `s03_acm`

### [ ] Certificato TLS dell'applicazione

**Nome logico:** dominio contenuto in `APP_HOST`  
**Console:** Certificate Manager → Certificates

Controllare:

- [ ] il certificato si trova in `eu-south-1`;
- [ ] il dominio principale coincide esattamente con `APP_HOST`;
- [ ] stato `Issued`, oppure `Pending validation` se manca ancora il record DNS;
- [ ] algoritmo RSA 2048 per il certificato richiesto dallo script;
- [ ] annotare l'ARN in `CERT_ARN`;
- [ ] se importato/self-signed, controllare la scadenza: ACM non lo rinnova.

Creazione/riparazione manuale:

1. Aprire ACM → **Request certificate**.
2. Scegliere **Request a public certificate**.
3. Inserire `APP_HOST`, scegliere validazione DNS e RSA 2048.
4. Creare nel DNS esterno il CNAME mostrato da ACM.
5. Attendere `Issued` e riportare l'ARN nello state o rieseguire `s03_acm`.

Per un certificato interno/self-signed usare **Import certificate** e fornire
certificato PEM, chiave privata PEM e, se presente, catena PEM. Un `.pfx` non si
carica direttamente nella schermata ACM: va prima estratto in PEM. Il `.pfx`
indicato da `BFF_PFX` è invece la credenziale BFF per Entra e non questo
certificato ALB.

Documentazione AWS: [richiesta certificato pubblico](https://docs.aws.amazon.com/acm/latest/userguide/acm-public-certificates.html),
[importazione](https://docs.aws.amazon.com/acm/latest/userguide/import-certificate.html).

## 2. Networking — `s04_network`

Documentazione AWS: [subnet](https://docs.aws.amazon.com/vpc/latest/userguide/create-subnets.html),
[Internet Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html),
[route table](https://docs.aws.amazon.com/vpc/latest/userguide/create-vpc-route-table.html),
[NAT instance](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html).

### [ ] VPC

**Nome:** `reverse-dr-poc-vpc`  
**Console:** VPC → Your VPCs

Controllare:

- [ ] CIDR IPv4 `10.42.0.0/16`;
- [ ] DNS resolution abilitata;
- [ ] DNS hostnames abilitati;
- [ ] tag `Name`, `Project`, `Environment` corretti.

Creazione manuale: VPC → **Create VPC** → **VPC only**; inserire il nome e il
CIDR, tenancy default. Dopo la creazione usare **Actions → Edit VPC settings** e
abilitare entrambe le opzioni DNS.

### [ ] Quattro subnet

**Console:** VPC → Subnets

| Check | Nome | AZ | CIDR | IP pubblico automatico | Uso |
|---|---|---|---|---|---|
| [ ] | `reverse-dr-poc-public-primary` | primaria | `10.42.0.0/24` | sì | NAT + ALB |
| [ ] | `reverse-dr-poc-public-witness` | witness | `10.42.1.0/27` | sì | seconda AZ ALB |
| [ ] | `reverse-dr-poc-private-primary` | primaria | `10.42.10.0/24` | no | nodi/pod/RDS |
| [ ] | `reverse-dr-poc-private-witness` | witness | `10.42.11.0/28` | no | control plane/RDS |

Tag aggiuntivi attesi:

- [ ] entrambe le pubbliche: `kubernetes.io/role/elb=1`, `Tier=public`;
- [ ] public witness: `Workloads=prohibited`;
- [ ] private primary: `Tier=private`, `Workloads=allowed`;
- [ ] private witness: `Tier=private`, `Workloads=prohibited`.

Creazione manuale: VPC → Subnets → **Create subnet**; scegliere la VPC, l'AZ e
il CIDR della tabella. Per le due pubbliche aprire **Actions → Edit subnet
settings** e abilitare l'assegnazione automatica IPv4 pubblica. Aggiungere poi i
tag indicati.

### [ ] Internet Gateway

**Nome:** `reverse-dr-poc-igw`  
**Console:** VPC → Internet gateways

Controllare:

- [ ] stato `Attached`;
- [ ] collegato alla VPC `reverse-dr-poc-vpc`.

Creazione manuale: **Create internet gateway**, assegnare il nome, quindi
**Actions → Attach to a VPC** e scegliere la VPC della PoC.

### [ ] Route table pubblica

**Nome:** `reverse-dr-poc-public`  
**Console:** VPC → Route tables

Controllare:

- [ ] VPC corretta;
- [ ] route locale `10.42.0.0/16 → local`;
- [ ] route `0.0.0.0/0 → reverse-dr-poc-igw`, stato `Active`;
- [ ] associazioni esplicite con entrambe le subnet pubbliche.

Creazione manuale: **Create route table**, selezionare la VPC; in **Routes**
aggiungere `0.0.0.0/0` con target Internet Gateway; in **Subnet associations**
associare le due subnet pubbliche.

### [ ] Security group della NAT instance

**Nome:** `reverse-dr-poc-nat`  
**Console:** EC2 → Security Groups

Controllare:

- [ ] VPC corretta;
- [ ] unica regola inbound: tutto il traffico da `10.42.10.0/24`;
- [ ] nessun inbound da `0.0.0.0/0`, altri CIDR o security group;
- [ ] outbound verso `0.0.0.0/0` consentito.

Creazione manuale: EC2 → Security Groups → **Create security group**; scegliere
la VPC, aggiungere inbound **All traffic** con sorgente `10.42.10.0/24` e lasciare
l'egress predefinito. Non aprire SSH: lo script non crea chiavi né accesso SSH.

### [ ] NAT instance EC2

**Nome:** `reverse-dr-poc-nat`  
**Console:** EC2 → Instances

Controllare:

- [ ] stato `Running` e status check `2/2 checks passed`;
- [ ] tipo `t4g.nano` e architettura ARM64;
- [ ] Amazon Linux 2023 ARM64, kernel 6.1;
- [ ] subnet `reverse-dr-poc-public-primary`;
- [ ] security group `reverse-dr-poc-nat`;
- [ ] volume root gp3 8 GiB, cifrato, delete on termination;
- [ ] IMDSv2 obbligatorio, hop limit `1`;
- [ ] source/destination check **disabilitato**;
- [ ] Elastic IP associato.

Creazione manuale:

1. EC2 → Instances → **Launch instance**.
2. Scegliere Amazon Linux 2023 ARM64 e `t4g.nano`.
3. Selezionare la subnet pubblica primaria, IP pubblico automatico e il SG NAT.
4. Non selezionare una key pair; configurare 8 GiB gp3 cifrato.
5. In Advanced details richiedere IMDSv2 e inserire questo user data:

```bash
#!/bin/bash
set -euxo pipefail
dnf install -y iptables-services
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/90-nat.conf
sysctl --system
default_interface="$(ip route show default | awk '{print $5; exit}')"
iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
iptables-save >/etc/sysconfig/iptables
systemctl enable --now iptables
```

6. Dopo il launch: **Actions → Networking → Change source/destination check** e
   disabilitarlo.
7. EC2 → Elastic IP addresses → **Allocate Elastic IP address**, quindi
   **Associate Elastic IP address** con la NAT instance.

> AWS preferisce NAT Gateway per disponibilità e gestione. Questa PoC usa una
> NAT instance deliberatamente per contenere i costi; non sostituirla senza
> cambiare l'architettura dichiarata.

### [ ] Route table privata primaria

**Nome:** `reverse-dr-poc-private-primary`  
**Console:** VPC → Route tables

Controllare:

- [ ] route locale `10.42.0.0/16 → local`;
- [ ] route `0.0.0.0/0 → NAT instance`, stato `Active`;
- [ ] associata solo a `reverse-dr-poc-private-primary`;
- [ ] la subnet witness privata non ha una route Internet.

Creazione manuale: creare una route table nella VPC, aggiungere la default route
con target **Instance**/interfaccia della NAT e associarla alla sola subnet
privata primaria.

## 3. IAM di base EKS — `s05_iam_eks`

Documentazione AWS: [creazione ruoli IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create.html),
[cluster role EKS](https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html),
[node role EKS](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html).

### [ ] Ruolo del control plane

**Nome:** `reverse-dr-poc-eks-cluster`

- [ ] trusted service `eks.amazonaws.com`;
- [ ] policy gestita `AmazonEKSClusterPolicy`.

Creazione manuale: IAM → Roles → **Create role** → AWS service → EKS → EKS
Cluster; allegare `AmazonEKSClusterPolicy` e assegnare il nome esatto.

### [ ] Ruolo dei nodi

**Nome:** `reverse-dr-poc-eks-node`

- [ ] trusted service `ec2.amazonaws.com`;
- [ ] `AmazonEKSWorkerNodePolicy`;
- [ ] `AmazonEC2ContainerRegistryPullOnly`;
- [ ] **non** contiene `AmazonEKS_CNI_Policy`, perché il CNI usa IRSA.

Creazione manuale: IAM → Roles → **Create role** → AWS service → EC2; allegare
le due policy indicate e usare il nome esatto.

## 4. Cluster EKS — `s06_eks`

Documentazione AWS: [creazione cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html),
[access entries](https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html),
[add-on](https://docs.aws.amazon.com/eks/latest/userguide/creating-an-add-on.html),
[managed node group](https://docs.aws.amazon.com/eks/latest/userguide/create-managed-node-group.html).

### [ ] Log group del control plane

**Nome:** `/aws/eks/reverse-dr-poc/cluster`  
**Console:** CloudWatch → Log groups

- [ ] presente se `EKS_LOG_TYPES` non è vuota;
- [ ] retention `30 giorni`, salvo override di `LOG_RETENTION_DAYS`;
- [ ] i log predefiniti dello script abilitano `authenticator`.

Creazione manuale: CloudWatch → Log groups → **Create log group**; inserire il
nome esatto, quindi Actions → **Edit retention setting** → 30 days.

### [ ] Cluster EKS

**Nome:** `reverse-dr-poc`  
**Console:** EKS → Clusters

Controllare:

- [ ] stato `Active`;
- [ ] EKS Auto Mode disabilitato;
- [ ] cluster role `reverse-dr-poc-eks-cluster`;
- [ ] authentication mode `EKS API`;
- [ ] bootstrap cluster creator admin permissions disabilitato;
- [ ] VPC della PoC e entrambe le subnet private;
- [ ] endpoint privato abilitato;
- [ ] endpoint pubblico disabilitato, salvo apertura temporanea `/32` esplicita;
- [ ] control plane logging coerente con `EKS_LOG_TYPES`.

Creazione manuale: EKS → **Add cluster → Create** → Custom configuration;
disabilitare Auto Mode, scegliere ruolo, VPC e le due subnet private. Nella
configurazione accesso scegliere EKS API e non concedere automaticamente
l'accesso amministratore al creatore. Configurare endpoint privato.

### [ ] Access entry amministrativa

**Nome logico:** ARN del ruolo SSO `AWSReservedSSO_AdministratorAccess...`, o
valore di `EKS_ADMIN_ROLE_ARN`  
**Console:** EKS → cluster → Access

- [ ] entry di tipo `Standard`;
- [ ] principal ARN è un ruolo, non l'ARN della sessione STS;
- [ ] policy `AmazonEKSClusterAdminPolicy` con scope `Cluster`.

Creazione manuale: tab Access → **Create access entry** → Standard → incollare
l'ARN del ruolo → Add access policy → `AmazonEKSClusterAdminPolicy` → scope
Cluster.

### [ ] Provider OIDC IAM del cluster

**Nome/URL:** issuer OIDC mostrato in EKS → Overview  
**Console:** IAM → Identity providers

- [ ] tipo OpenID Connect;
- [ ] URL identica all'issuer del cluster, incluso il path `/id/...`;
- [ ] audience `sts.amazonaws.com`.

Creazione manuale: IAM → Identity providers → **Add provider** → OpenID Connect;
incollare l'issuer e aggiungere `sts.amazonaws.com`. Documentazione:
[provider OIDC IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html).

### [ ] Ruoli IRSA degli add-on

| Check | Ruolo | Service account vincolato | Policy gestita |
|---|---|---|---|
| [ ] | `reverse-dr-poc-vpc-cni` | `kube-system/aws-node` | `AmazonEKS_CNI_Policy` |
| [ ] | `reverse-dr-poc-ebs-csi` | `kube-system/ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` |

Per ciascun ruolo controllare la trust policy:

- [ ] principal federato = ARN del provider OIDC del cluster;
- [ ] action `sts:AssumeRoleWithWebIdentity`;
- [ ] condizione `<OIDC_HOST>:aud = sts.amazonaws.com`;
- [ ] condizione `<OIDC_HOST>:sub = system:serviceaccount:<namespace>:<sa>`.

Creazione manuale: IAM → Roles → **Create role** → Web identity → provider OIDC
del cluster → audience `sts.amazonaws.com`; allegare la policy della tabella.
Aprire poi **Trust relationships → Edit trust policy** e restringere anche il
claim `sub` al service account esatto.

### [ ] Add-on gestiti EKS

**Console:** EKS → cluster → Add-ons

| Check | Add-on | Ruolo IAM |
|---|---|---|
| [ ] | `vpc-cni` | `reverse-dr-poc-vpc-cni` |
| [ ] | `kube-proxy` | nessuno |
| [ ] | `coredns` | nessuno |
| [ ] | `aws-ebs-csi-driver` | `reverse-dr-poc-ebs-csi` |

Controllare stato `Active` e versione compatibile con la versione Kubernetes.
CoreDNS può risultare degradato finché non esiste un nodo Ready.

Creazione manuale: tab Add-ons → **Get more add-ons**; selezionare la versione
compatibile, scegliere IRSA per CNI/EBS e, in caso di conflitto con componenti
self-managed, usare Override solo dopo aver verificato le personalizzazioni.

### [ ] Launch template dei nodi

**Nome:** `reverse-dr-poc-node`  
**Console:** EC2 → Launch Templates

- [ ] root device `/dev/xvda`, gp3 30 GiB, cifrato, delete on termination;
- [ ] IMDSv2 richiesto;
- [ ] metadata hop limit `2`;
- [ ] nessuna AMI o subnet fissata nel template.

Creazione manuale: EC2 → Launch Templates → **Create launch template**;
configurare solo storage e metadata. L'AMI EKS, il tipo istanza e la subnet
vengono impostati dal managed node group.

### [ ] Managed node group

**Nome:** `reverse-dr-poc-primary`  
**Console:** EKS → cluster → Compute

Controllare:

- [ ] stato `Active`;
- [ ] node role `reverse-dr-poc-eks-node`;
- [ ] sola subnet `reverse-dr-poc-private-primary`;
- [ ] On-Demand, `t3.medium`, Amazon Linux 2023 x86_64;
- [ ] launch template `reverse-dr-poc-node`;
- [ ] min/desired/max `1/1/2`;
- [ ] label `reverse-dr.io/failure-domain=primary-az`;
- [ ] label `reverse-dr.io/workload-tier=application`;
- [ ] almeno un nodo compare `Ready` nella sezione Nodes/Kubernetes resources.

Creazione manuale: EKS → cluster → Compute → **Add node group**; inserire nome e
node role, poi launch template, capacità, tipo istanza, scaling e **solo** la
subnet privata primaria. Aggiungere entrambe le label.

Se lo stato è `Create failed`, aprire **Health issues**. Correggere prima NAT,
route, ruolo IAM e add-on CNI; eliminare il node group fallito e ricrearlo. Non
creare manualmente EC2 o Auto Scaling Group: devono restare gestiti da EKS.

### [ ] Risorse derivate e gestite da EKS

Il cluster/node group crea anche risorse con nomi generati:

- [ ] cluster security group visibile nel tab Networking del cluster;
- [ ] Auto Scaling Group collegato al managed node group;
- [ ] almeno una EC2 worker `t3.medium` nella subnet privata primaria;
- [ ] volume EBS root gp3 cifrato da 30 GiB per ogni worker;
- [ ] ENI dei nodi e del control plane nelle subnet previste.

Controllarle da EKS → Compute/Networking e dai link verso EC2/Auto Scaling. Se
mancano, riparare o ricreare cluster/node group tramite EKS: non creare
singolarmente Auto Scaling Group, worker, ENI o cluster SG.

## 5. ECR — `s07_ecr` e `s14_images`

Documentazione AWS: [creazione repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-create.html),
[tag immutabili](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html),
[lifecycle policy](https://docs.aws.amazon.com/AmazonECR/latest/userguide/lp_creation.html).

### [ ] Cinque repository privati

**Console:** ECR → Private registry → Repositories

| Check | Repository | Immagini attese |
|---|---|---|
| [ ] | `reverse-dr-poc-frontend` | frontend web |
| [ ] | `reverse-dr-poc-bff` | BFF |
| [ ] | `reverse-dr-poc-ticket` | ticket service |
| [ ] | `reverse-dr-poc-automation` | automation service + tag `backup-*` |
| [ ] | `reverse-dr-poc-ticket-processor` | immagine Lambda |

Per ciascuno:

- [ ] tag immutabili;
- [ ] scan on push abilitato;
- [ ] cifratura AES-256;
- [ ] lifecycle: eliminazione untagged dopo 7 giorni;
- [ ] lifecycle: mantenere le ultime 20 immagini.

Creazione manuale: ECR → **Create repository** → Private; usare il nome esatto,
selezionare Immutable, basic scan on push e AES-256. Dopo la creazione aprire
Lifecycle policy e inserire le due regole.

### [ ] Immagini pubblicate

Controllare che ogni repository contenga il tag `IMAGE_TAG`; `automation` deve
contenere anche `BACKUP_IMAGE_TAG=backup-<IMAGE_TAG>`. L'immagine
`ticket-processor` deve avere un singolo manifest Docker v2 e architettura
x86_64, non un multi-architecture image index.

Le immagini non si costruiscono dalla Console AWS. Se mancano, usare Docker e
rieseguire `s14_images`; ECR mostra in ogni repository il comando **View push
commands**. Non riutilizzare un tag con codice differente perché i repository
sono immutabili.

## 6. RDS PostgreSQL — `s08_rds` e `s08b_rds_ingress`

Documentazione AWS: [creazione DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.html),
[impostazioni RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.Settings.html).

### [ ] Security group PostgreSQL

**Nome:** `reverse-dr-poc-postgres`  
**Console:** EC2/VPC → Security Groups

- [ ] inbound TCP 5432;
- [ ] source = cluster security group creato da EKS, non un CIDR pubblico;
- [ ] nessuna regola `0.0.0.0/0`.

Creazione manuale: creare il SG nella VPC senza ingress; dopo la creazione del
cluster recuperare il suo **Cluster security group** e aggiungerlo come source
della regola PostgreSQL 5432.

### [ ] DB subnet group

**Nome:** `reverse-dr-poc-postgres`  
**Console:** RDS → Subnet groups

- [ ] VPC della PoC;
- [ ] subnet privata primaria e privata witness;
- [ ] copre due AZ.

Creazione manuale: RDS → Subnet groups → **Create DB subnet group**; scegliere
VPC, entrambe le AZ e le due subnet private.

### [ ] DB instance PostgreSQL

**Identifier:** `reverse-dr-poc-postgres`  
**Console:** RDS → Databases

Controllare:

- [ ] stato `Available`;
- [ ] PostgreSQL major 16, database iniziale `helios`;
- [ ] master username `platform_admin`;
- [ ] credenziali master gestite da Secrets Manager;
- [ ] classe `db.t4g.micro`;
- [ ] gp3, 20 GiB iniziali, autoscaling massimo 100 GiB, cifrato;
- [ ] Single-AZ nella AZ primaria, Multi-AZ disabilitato;
- [ ] public access `No`;
- [ ] DB subnet group e SG indicati sopra;
- [ ] IAM database authentication abilitata;
- [ ] backup retention 7 giorni;
- [ ] export dei log PostgreSQL verso CloudWatch non configurato;
- [ ] Performance Insights e deletion protection disabilitati;
- [ ] endpoint annotato come `DB_HOST` e porta 5432.

Creazione manuale: RDS → **Create database** → Standard create → PostgreSQL;
inserire esattamente i valori sopra. Scegliere **Manage master credentials in AWS
Secrets Manager**, Dev/Test, Single DB instance e connettività manuale nella VPC.

### [ ] Secret master gestito da RDS

Nel dettaglio DB, sezione Configuration, verificare che **Master credentials ARN**
punti a un secret Secrets Manager in stato disponibile. È una risorsa derivata
da RDS e il nome contiene un suffisso AWS. Non crearla come secret applicativo:
se manca, modificare il DB e abilitare la gestione delle credenziali master.

## 7. S3 — `s09_s3`

Documentazione AWS: [creazione bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/create-bucket-overview.html),
[Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html),
[versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html).

### [ ] Bucket backup e frontend

| Check | Nome |
|---|---|
| [ ] | `reverse-dr-poc-backup-<ACCOUNT_ID>-eu-south-1` |
| [ ] | `reverse-dr-poc-frontend-<ACCOUNT_ID>-eu-south-1` |

Per entrambi:

- [ ] Regione `eu-south-1`;
- [ ] versioning Enabled;
- [ ] default encryption SSE-S3/AES-256;
- [ ] tutti e quattro i Block Public Access abilitati;
- [ ] ACL disabilitate/Bucket owner enforced consigliato;
- [ ] nessuna bucket policy pubblica.

Creazione manuale: S3 → General purpose buckets → **Create bucket**; usare il
nome esatto, Regione Milano, Bucket owner enforced, Block Public Access completo,
versioning Enabled e SSE-S3.

Solo sul bucket backup verificare una lifecycle rule `postgres-archive`:

- [ ] filtro prefisso `postgres/`;
- [ ] transizione a Glacier Instant Retrieval dopo 30 giorni;
- [ ] scadenza dopo 365 giorni.

Se manca: bucket → Management → Lifecycle rules → **Create lifecycle rule**.

## 8. Secrets Manager — `s10_secrets` e `s12_bootstrap`

Documentazione AWS: [creare un secret](https://docs.aws.amazon.com/secretsmanager/latest/userguide/create_secret.html),
[struttura del secret](https://docs.aws.amazon.com/secretsmanager/latest/userguide/whats-in-a-secret.html).

### [ ] Secret applicativi

| Check | Nome | Chiavi attese dopo `s12_bootstrap` |
|---|---|---|
| [ ] | `reverse-dr-poc/application/database` | `DATABASE_URL` |
| [ ] | `reverse-dr-poc/application/config` | `OIDC_CLIENT_PRIVATE_KEY`, `OIDC_CLIENT_CERTIFICATE`, `SESSION_ENCRYPTION_KEY` |

Controllare:

- [ ] stato disponibile e versione `AWSCURRENT` presente;
- [ ] cifratura con `aws/secretsmanager`, salvo scelta KMS esplicita;
- [ ] rotation automatica disabilitata, perché lo script non la configura;
- [ ] i ruoli IRSA hanno accesso soltanto agli ARN necessari.

Creazione manuale: Secrets Manager → **Store a new secret** → Other type of
secret; usare il nome esatto. Per il database inserire JSON con `DATABASE_URL`.
Per il config incollare le chiavi PEM preservando i newline e generare una chiave
di sessione forte. Preferire comunque `s12_bootstrap`, che estrae in sicurezza il
`.pfx` protetto da password e mantiene coerenti certificato e chiave.

## 9. IAM workload/IRSA — `s11_irsa`

Documentazione AWS: [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html),
[policy IAM via Console](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_create-console.html).

| Check | Ruolo | Namespace/service account | Inline policy |
|---|---|---|---|
| [ ] | `reverse-dr-poc-bff` | `helios-desk/helios-bff` | `application-secrets` |
| [ ] | `reverse-dr-poc-ticket` | `helios-desk/helios-ticket-service` | `database-and-events` |
| [ ] | `reverse-dr-poc-automation` | `helios-desk/helios-automation-service` | `secrets-queue-lambda` |
| [ ] | `reverse-dr-poc-backup` | `helios-desk/helios-postgres-backup` | `db-and-backup-prefix` |
| [ ] | `reverse-dr-poc-aws-load-balancer-controller` | `kube-system/aws-load-balancer-controller` | `alb-controller` |

Per ogni ruolo controllare la stessa struttura IRSA descritta per gli add-on:
OIDC principal corretto, audience `sts.amazonaws.com` e `sub` limitato al singolo
service account.

Permessi minimi attesi:

- BFF: lettura dei due secret applicativi;
- ticket: lettura secret e `events:PutEvents` sul bus applicativo;
- automation: lettura secret, consume SQS e invoke della Lambda;
- backup: lettura secret DB, oggetti `s3://<backup>/postgres/*` e ListBucket solo
  sul prefisso `postgres/*`;
- ALB controller: policy inline `alb-controller` ricavata da
  `modules/eks/policies/aws-load-balancer-controller-v3.4.2.json.tftpl`, con
  `${vpc_arn}` sostituito dall'ARN della VPC.

Creazione manuale: creare un ruolo Web identity per ogni riga, modificare il
trust `sub`, quindi Permissions → **Add permissions → Create inline policy**.
Per evitare errori o permessi eccessivi, copiare il JSON generato dallo script o
dal runbook invece di ricostruirlo con il visual editor.

## 10. Bootstrap applicativo — `s12_bootstrap`

Questa fase non crea una nuova risorsa AWS autonoma: aggiunge versioni ai due
secret, crea il ruolo PostgreSQL `helios_app` e usa pod Kubernetes
temporanei.

- [ ] nei secret esiste una versione `AWSCURRENT` coerente;
- [ ] nel database esiste il ruolo `helios_app` con accesso al DB `helios`;
- [ ] il secret Kubernetes temporaneo `pg-bootstrap` non esiste più.

Non è possibile completare questa fase dalla sola Console AWS. Se lo script non
funziona, usare un pod PostgreSQL temporaneo nel cluster, creare/aggiornare
`helios_app`, quindi modificare i due secret in Secrets Manager. Non esporre mai
la password master o la password del `.pfx` nella shell history.

## 11. SQS ed EventBridge — `s13_events`

Documentazione AWS: [queue standard](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/creating-sqs-standard-queues.html),
[DLQ](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue.html),
[event bus](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-event-bus.html),
[archive](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-archive-event.html).

### [ ] Dead-letter queue SQS

**Nome:** `reverse-dr-poc-ticket-automation-dlq`

- [ ] tipo Standard;
- [ ] message retention 14 giorni (`1209600` secondi);
- [ ] cifratura SQS gestita da AWS/default; lo script non forza esplicitamente
  questo attributo, quindi controllarlo in Console.

Creazione manuale: SQS → **Create queue** → Standard; inserire nome e retention
14 days, lasciare gli altri valori predefiniti.

### [ ] Queue applicativa SQS

**Nome:** `reverse-dr-poc-ticket-automation`

- [ ] tipo Standard;
- [ ] visibility timeout 180 secondi;
- [ ] retention 4 giorni (`345600` secondi);
- [ ] DLQ impostata alla queue precedente;
- [ ] maximum receives `5`;
- [ ] access policy consente `sqs:SendMessage` al service principal
  `events.amazonaws.com`, limitato tramite `aws:SourceArn` alla rule EventBridge.

Creazione manuale: creare una Standard queue con i parametri sopra; sezione
Dead-letter queue → Enabled → scegliere la DLQ → maximum receives 5. Dopo la
creazione modificare Access policy con la rule come SourceArn.

### [ ] Event bus e archive

| Check | Tipo | Nome | Configurazione |
|---|---|---|---|
| [ ] | Custom event bus | `reverse-dr-poc-application` | AWS-owned encryption |
| [ ] | Archive | `reverse-dr-poc-application` | source bus precedente, retention 7 giorni |

Creazione manuale: EventBridge → Event buses → **Create event bus**; usare il
nome esatto e AWS-owned key. Poi Archives → **Create archive**, selezionare il
bus e retention 7 days.

### [ ] Rule e target EventBridge

**Rule:** `reverse-dr-poc-ticket-automation` sul bus applicativo

- [ ] stato Enabled;
- [ ] event pattern:

```json
{
  "source": ["helios.ticket"],
  "detail-type": [
    "helios.ticket.created.v1",
    "helios.automation.requested.v1"
  ]
}
```

- [ ] target SQS = `reverse-dr-poc-ticket-automation`;
- [ ] target ID logico `ticket-automation-queue`.

Creazione manuale: EventBridge → Rules → **Create rule**; selezionare il custom
bus, rule with event pattern, Custom pattern JSON e poi target SQS. Verificare la
queue policy se il test target restituisce AccessDenied.

## 12. Lambda — `s14_images/_lambda`

Documentazione AWS: [funzione da container image](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html),
[reserved concurrency](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html).

### [ ] Execution role Lambda

**Nome:** `reverse-dr-poc-ticket-automation-lambda`

- [ ] trust `lambda.amazonaws.com`;
- [ ] policy gestita `AWSLambdaBasicExecutionRole`;
- [ ] inline policy `read-secrets` con `secretsmanager:GetSecretValue` limitato ai
  due secret applicativi.

Creazione manuale: IAM → Roles → Create role → AWS service → Lambda; allegare la
managed policy e aggiungere l'inline policy con gli ARN completi dei secret.

### [ ] Log group Lambda

**Nome:** `/aws/lambda/reverse-dr-poc-ticket-automation`

- [ ] esiste se `EKS_LOG_TYPES` non è vuota o dopo la prima invocazione;
- [ ] non contiene errori `AccessDenied` o manifest image unsupported.

Creazione manuale: CloudWatch → Log groups → Create log group. Lo script corrente
non imposta la retention per questo gruppo; per coerenza cost-conscious impostare
manualmente 30 giorni.

### [ ] Function e trigger

**Nome:** `reverse-dr-poc-ticket-automation`

- [ ] package type Container image;
- [ ] image dal repository `reverse-dr-poc-ticket-processor`, referenziata al
  digest corrispondente a `IMAGE_TAG`;
- [ ] architettura x86_64;
- [ ] execution role sopra;
- [ ] memory 256 MB, timeout 30 secondi;
- [ ] reserved concurrency `2`;
- [ ] stato `Active`;
- [ ] trigger SQS sulla queue applicativa, batch size 10, batch window 5 secondi.

Creazione manuale: Lambda → Functions → **Create function** → Container image;
inserire nome, scegliere l'immagine ECR e x86_64, poi execution role esistente.
Dopo la creazione modificare General configuration, Concurrency e aggiungere il
trigger SQS con batch size/window indicati.

## 13. Componenti Kubernetes — `s15_platform`

Queste risorse vivono nell'API Kubernetes, non come risorse autonome della
Console AWS. Possono essere visualizzate in EKS → cluster → Kubernetes resources
se il principal ha accesso.

### [ ] External Secrets Operator

- [ ] namespace `external-secrets`;
- [ ] deployment `external-secrets` Ready 1/1;
- [ ] webhook e cert controller Ready 1/1;
- [ ] CRD ExternalSecret e SecretStore installate.

Ripristino manuale corretto:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  -f "$REPO_ROOT/automazione/infra/aws/kubernetes/external-secrets-values.yaml.example"
```

### [ ] AWS Load Balancer Controller

- [ ] service account `kube-system/aws-load-balancer-controller` con annotation
  IRSA verso il ruolo omonimo;
- [ ] deployment `aws-load-balancer-controller` Ready 1/1;
- [ ] valori Helm: cluster `reverse-dr-poc`, `eu-south-1`, VPC corretta;
- [ ] Shield, WAF e WAFv2 disabilitati come da PoC.

Ripristino: rieseguire `s15_platform` oppure applicare il ServiceAccount renderizzato
e `helm upgrade --install` con il file valori renderizzato. Non installare il
controller dalla schermata EKS Add-ons: in questo progetto è gestito con Helm.

## 14. Overlay applicativo e risorse derivate — `s16_overlay`

### [ ] Oggetti Kubernetes

Nel namespace `helios-desk` verificare:

- [ ] Namespace `helios-desk`;
- [ ] ServiceAccount: `helios-web`, `helios-bff`, `helios-ticket-service`,
  `helios-automation-service`, `helios-postgres-backup`;
- [ ] ConfigMap `helios-aws-config`;
- [ ] SecretStore: `aws-bff-secrets`, `aws-ticket-secrets`,
  `aws-automation-secrets`, `aws-backup-secrets`;
- [ ] ExternalSecret: `helios-bff-database`, `helios-bff-runtime`,
  `helios-ticket-database`, `helios-automation-database`,
  `helios-backup-database`;
- [ ] Deployment e Service: `helios-web`, `helios-bff`,
  `helios-ticket-service`, `helios-automation-service`;
- [ ] CronJob `helios-postgres-backup`, schedule ogni 10 minuti;
- [ ] IngressClassParams e IngressClass `helios-public-alb`;
- [ ] Ingress `helios-public`.

Ripristino manuale: non ricreare singolarmente dalla Console. Renderizzare i
placeholder con `s16_overlay`, controllare che non restino stringhe `REPLACE_` e
applicare `rendered.yaml` con `kubectl apply`. Questo mantiene ownership,
annotation IRSA e riferimenti ai secret coerenti.

### [ ] Application Load Balancer creato dal controller

**Console:** EC2 → Load Balancers / Target Groups

Il nome fisico è generato dal controller e non è stabile. Identificarlo con i
tag `Project=reverse-dr`, `Environment=poc`,
`ManagedBy=aws-load-balancer-controller`.

Controllare:

- [ ] scheme internet-facing, IPv4;
- [ ] distribuito nelle due subnet pubbliche;
- [ ] listener HTTP 80 con redirect a HTTPS 443;
- [ ] listener HTTPS 443 con il certificato ACM corretto;
- [ ] target type IP;
- [ ] security group generato dal controller: ingresso pubblico solo sulle porte
  dei listener e uscita verso i target;
- [ ] ENI dell'ALB presenti nelle due subnet pubbliche;
- [ ] routing `/api` verso `helios-bff:8000`;
- [ ] routing `/` verso `helios-web:8080`;
- [ ] target group con target healthy;
- [ ] drop invalid header fields abilitato e idle timeout 60 secondi.

Se manca, non creare a mano ALB, listener e target group: divergerebbero
dall'Ingress e non seguirebbero i pod. Riparare controller/IRSA/subnet tag, poi
rieseguire:

```bash
kubectl apply -f "$OVERLAY_DIR/rendered.yaml"
kubectl -n helios-desk describe ingress helios-public
kubectl -n kube-system logs deploy/aws-load-balancer-controller
```

## 15. Migrazioni e verifica finale — `s17_migrations` / `verify`

Le migrazioni creano schema e tabelle PostgreSQL, non risorse della Console AWS.

- [ ] job di migrazione completato senza errori;
- [ ] tutti i deployment applicativi Ready;
- [ ] Ingress contiene un hostname ALB;
- [ ] `https://<APP_HOST>/healthz` risponde;
- [ ] `https://<APP_HOST>/api/v1/platform/status` restituisce JSON valido;
- [ ] nel bucket backup esistono oggetti `postgres/*.dump` e checksum;
- [ ] RDS è Single-AZ, privato e nella AZ primaria;
- [ ] node group usa solo la subnet privata primaria;
- [ ] nessun NAT Gateway disponibile nella VPC.

Se le migrazioni falliscono, usare il Job/script indicato nel runbook con il
secret Kubernetes `helios-bff-database`, quindi riavviare i deployment. Non
eseguire SQL dalla Query Editor con credenziali applicative salvate nel browser.

## 16. Ordine di ripristino consigliato

Quando mancano più risorse, ricrearle in questo ordine:

1. ACM e input esterni;
2. VPC, subnet, IGW, route, NAT SG, NAT instance ed EIP;
3. IAM cluster/node;
4. EKS, access entry, OIDC, ruoli add-on, add-on e node group;
5. ECR e immagini;
6. RDS e ingress SG;
7. S3 e Secrets Manager;
8. ruoli IRSA workload;
9. SQS, EventBridge, Lambda;
10. Helm platform;
11. bootstrap database/secret con `s12_bootstrap`;
12. overlay Kubernetes e migrazioni;
13. DNS finale verso l'hostname ALB.

Quando la risorsa è stata creata manualmente con nome e configurazione corretti,
rieseguire la sezione corrispondente di `provision.sh`: lo script dovrebbe
adottarla tramite lookup e riconciliare i campi gestiti. Conservare in
`~/.reverse-dr/state.env` gli ID che le sezioni successive richiedono.

## 17. Risorse volutamente assenti

Non segnare come errore l'assenza di:

- [ ] NAT Gateway;
- [ ] Route 53 hosted zone o record DNS finale;
- [ ] WAF, Shield Advanced o Redis/ElastiCache;
- [ ] ALB creato direttamente dallo script prima dell'Ingress;
- [ ] chiavi EC2 e regole SSH per la NAT instance.

Il DNS finale appartiene al sistema DNS esterno indicato da `APP_HOST`. L'ALB
compare soltanto quando AWS Load Balancer Controller riconcilia l'Ingress.
