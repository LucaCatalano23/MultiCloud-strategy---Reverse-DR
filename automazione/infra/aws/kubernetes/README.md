# EKS cloud overlay

Template Kustomize per il primary AWS. Rispetta `automazione/contracts/deployment-contract.json`:

- namespace `helios-desk`;
- `helios-web:8080` con health `/healthz`;
- `helios-bff:8000`, `helios-ticket-service:8001`, `helios-automation-service:8002` con health `/health/ready`;
- API pubblica `/api/v1` tramite BFF;
- Entra ID come identity provider primary.

I file contengono placeholder `REPLACE_*` e non sono destinati a essere applicati direttamente. Nessuna credenziale deve essere inserita nei manifest o in Kustomize.

## Endpoint canonico

`ingress.yaml` crea, tramite AWS Load Balancer Controller, un solo endpoint same-origin:

L'origin contrattuale e `https://heliospoc.ggg.it`, identico a quello del sito
on-prem. `REPLACE_APP_HOSTNAME` viene valorizzato esclusivamente con questo nome:
cookie `__Host-*`, CSRF e callback Entra non devono cambiare durante il failover.

| Path | Service |
|---|---|
| `/api/*` | `helios-bff:8000` |
| `/*` | `helios-web:8080` |

I health check sono annotati sui singoli Service (`/health/ready` per BFF, `/healthz` per web), così ogni target group usa il proprio contratto. `IngressClassParams` limita la classe ALB al namespace `helios-desk`, evitando che namespace non fidati si uniscano allo stesso IngressGroup.

CloudFront/S3 non è l'endpoint canonico: non inoltra `/api`, quindi non preserva il modello BFF con cookie `__Host-*`, CSRF e callback OIDC same-origin.

### Variante senza ACM: edge solo-HTTP (opt-in)

Se non hai un ACM *validato pubblicamente* ma puoi **importare un self-signed in
ACM** (`aws acm import-certificate`, già ciò che fa `provision.sh`), resta
sull'`ingress.yaml` di default: l'edge è HTTPS e il login `__Host-*` funziona —
è la scelta preferita. Questa variante serve **solo** quando non è caricabile
alcun certificato sull'ALB (né ACM, né self-signed importato, né IAM server
certificate): l'ALB non può allora esporre il listener HTTPS. In quel caso
`ingress-http-only.yaml`, gemello di `ingress.yaml`, ha un solo listener
`HTTP:80`, senza `certificate-arn` né `ssl-redirect`. È **opt-in**: non è in
`kustomization.yaml`; per usarla sostituisci `- ingress.yaml` con
`- ingress-http-only.yaml` (o applicala al posto dell'altra). Richiede solo
`REPLACE_APP_HOSTNAME`, nessun ARN ACM.

Serve a rendere osservabile il primario dal controller DR quando manca l'ACM: il
probe di `helpdesk-dr` in modalità `CLOUD_PROBE_MODE=http` connette all'IP
dell'ALB tenendo `Host: heliospoc.ggg.it`, e il listener `:80` risponde `200` su
`/health/ready`. Con l'Ingress ACM di default il `ssl-redirect` restituirebbe
invece `301`, che il probe interpreterebbe come outage.

**Limite dichiarato — non è un edge di produzione per il traffico utente.** I
cookie `__Host-*`, il CSRF e la callback OIDC richiedono `https://` same-origin
(sezione "Endpoint canonico" qui sopra): su HTTP in chiaro il browser rifiuta i
cookie `__Host-*` e il login si rompe. La variante è quindi adatta al probe di
readiness / agli ambienti non-produzione; per gli utenti reali la TLS va
comunque terminata (ACM sull'ALB o TLS a un altro livello).

**Provisioning.** `provision-cli/provision.sh` (`s16_overlay`) richiede
`CERT_ARN` e sostituisce `REPLACE_ACM_CERTIFICATE_ARN`: il percorso senza-ACM
salta quel flusso e applica manualmente l'overlay con la variante solo-HTTP. Lo
script non è stato modificato per questo caso.

## Placeholder

| Placeholder | Fonte |
|---|---|
| `REPLACE_AWS_REGION` | `var.aws_region` |
| `REPLACE_VPC_ID` | output `vpc_id` |
| `REPLACE_*_ECR_REPOSITORY` | output `ecr_repository_urls` |
| `REPLACE_IMAGE_TAG` | tag immutabile prodotto dalla CI; preferire digest in un overlay release |
| `REPLACE_*_IRSA_ROLE_ARN` | output `workload_irsa_role_arns` |
| `REPLACE_LOAD_BALANCER_CONTROLLER_ROLE_ARN` | output omonimo Terraform |
| `REPLACE_APPLICATION_*_SECRET_ARN` | output `application_secret_arns` |
| `REPLACE_BACKUP_BUCKET_NAME` | output `backup_bucket_name` |
| `REPLACE_AUTOMATION_LAMBDA_FUNCTION_NAME` | output omonimo; richiede Lambda abilitata |
| `REPLACE_ACM_CERTIFICATE_ARN` | certificato regionale associato al dominio dell'ALB |
| `REPLACE_APP_HOSTNAME` | `heliospoc.ggg.it`, hostname canonico del deployment contract |
| `REPLACE_ENTRA_API_CLIENT_ID_GUID` | `identity.audience.value` del deployment contract, fornito dal team identità |
| altri `REPLACE_ENTRA_*` | valori non-secret forniti dal team identità (issuer, client ID BFF, endpoint OIDC) |

Il repository `automation` ospita anche il target immagine backup con tag dedicato `REPLACE_BACKUP_IMAGE_TAG`; quell'immagine deve contenere una versione `pg_dump` compatibile con RDS PostgreSQL, AWS CLI v2, `sed` e `sha256sum`.

## Secret injection

Il flusso usa [External Secrets Operator](https://external-secrets.io/latest/provider/aws-secrets-manager/) `v1` con token IRSA temporanei:

1. ogni `SecretStore` usa `auth.jwt.serviceAccountRef` verso il service account del workload;
2. la trust policy Terraform limita `sub` a namespace e service account esatti;
3. ogni IAM role legge solo gli ARN Secrets Manager necessari;
4. `ExternalSecret` materializza Secret Kubernetes distinti per workload;
5. i Deployment consumano solo le chiavi richieste.

Il secret database deve contenere `DATABASE_URL`. Il secret config deve contenere `OIDC_CLIENT_PRIVATE_KEY`, `OIDC_CLIENT_CERTIFICATE` e `SESSION_ENCRYPTION_KEY`: il primario si autentica con `private_key_jwt`, non con un client secret (vedi il README di `infra/aws`). Il valore database è atteso nel formato SQLAlchemy async `postgresql+asyncpg://...`; il CronJob sostituisce solo lo schema con `postgresql://` in memoria prima di invocare `pg_dump` e non stampa mai l'URL.

Installare External Secrets prima del kustomization; i CRD `SecretStore` e `ExternalSecret` altrimenti non esistono. `external-secrets-values.yaml.example` mantiene una singola replica per contenere il costo della PoC. L'operator deve poter creare token via Kubernetes `TokenRequest` per i service account referenziati.

## Controller ALB

1. sostituire il ruolo in `aws-load-balancer-controller-serviceaccount.yaml` e creare quel service account;
2. valorizzare `aws-load-balancer-controller-values.yaml.example` con cluster, regione e VPC;
3. installare una versione del chart compatibile con la policy IAM `v3.4.2` inclusa nel modulo Terraform;
4. impostare `serviceAccount.create=false` e usare `kube-system/aws-load-balancer-controller`.

Le due subnet pubbliche sono auto-discoverable tramite `kubernetes.io/role/elb=1`. La subnet witness è `/27` esclusivamente per soddisfare il requisito ALB; tutti i pod restano nella AZ primaria.

## Backup RDS verso S3

`backup-cronjob.yaml` sostituisce il vecchio backup che cercava un pod PostgreSQL locale. Ogni dieci minuti:

1. esegue `pg_dump --format=custom --compress=9` verso un `emptyDir` temporaneo;
2. genera SHA-256;
3. carica dump e checksum sotto `s3://<bucket>/postgres/<timestamp>.*`;
4. usa soltanto il ruolo IRSA `backup`, limitato a quel prefix.

`concurrencyPolicy: Forbid` evita backup sovrapposti. Il limite `emptyDir` è 2 GiB: aumentarlo con una valutazione di ephemeral storage prima che il database si avvicini a quella dimensione. Il CronJob non sostituisce gli automated backup RDS; crea l'artefatto portabile necessario al restore on-prem.

## Rendering e validazione

Prima di produrre YAML, sostituire tutti i placeholder in una copia/overlay di deployment. Verifica minima:

```powershell
rg "REPLACE_" .
kubectl kustomize . > rendered.yaml
kubeconform -strict -summary -ignore-missing-schemas rendered.yaml
```

`-ignore-missing-schemas` è necessario soltanto per i CRD ALB/External Secrets; i tipi Kubernetes built-in devono comunque validare. Ispezionare il render per assicurarsi che non contenga valori secret.

Sequenza operativa suggerita, non eseguita da questo repository:

1. applicare Terraform dopo review/autorizzazione;
2. creare il valore dei due secret applicativi;
3. installare External Secrets e AWS Load Balancer Controller;
4. pubblicare immagini ECR immutabili, incluso il target backup;
5. renderizzare e validare l'overlay;
6. applicare namespace/service account, poi secret store, workload, CronJob e Ingress;
7. associare il DNS all'hostname ALB e verificare health, login OIDC e backup/restore.
