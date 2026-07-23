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

| Path | Service |
|---|---|
| `/api/*` | `helios-bff:8000` |
| `/*` | `helios-web:8080` |

I health check sono annotati sui singoli Service (`/health/ready` per BFF, `/healthz` per web), così ogni target group usa il proprio contratto. `IngressClassParams` limita la classe ALB al namespace `helios-desk`, evitando che namespace non fidati si uniscano allo stesso IngressGroup.

CloudFront/S3 non è l'endpoint canonico: non inoltra `/api`, quindi non preserva il modello BFF con cookie `__Host-*`, CSRF e callback OIDC same-origin.

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
| `REPLACE_APP_HOSTNAME` | hostname Route 53/DNS esterno scelto per la PoC |
| `REPLACE_ENTRA_API_CLIENT_ID_GUID` | output canonico `entra.api_application_client_id` |
| altri `REPLACE_ENTRA_*` | output non-secret del modulo Entra (issuer, client ID BFF, endpoint OIDC) |

Il repository `automation` ospita anche il target immagine backup con tag dedicato `REPLACE_BACKUP_IMAGE_TAG`; quell'immagine deve contenere una versione `pg_dump` compatibile con RDS PostgreSQL, AWS CLI v2, `sed` e `sha256sum`.

## Secret injection

Il flusso usa [External Secrets Operator](https://external-secrets.io/latest/provider/aws-secrets-manager/) `v1` con token IRSA temporanei:

1. ogni `SecretStore` usa `auth.jwt.serviceAccountRef` verso il service account del workload;
2. la trust policy Terraform limita `sub` a namespace e service account esatti;
3. ogni IAM role legge solo gli ARN Secrets Manager necessari;
4. `ExternalSecret` materializza Secret Kubernetes distinti per workload;
5. i Deployment consumano solo le chiavi richieste.

Il secret database deve contenere `DATABASE_URL`. Il secret config deve contenere `OIDC_CLIENT_SECRET` e `SESSION_ENCRYPTION_KEY`. Il valore database è atteso nel formato SQLAlchemy async `postgresql+asyncpg://...`; il CronJob sostituisce solo lo schema con `postgresql://` in memoria prima di invocare `pg_dump` e non stampa mai l'URL.

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
