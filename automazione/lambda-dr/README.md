# Lambda DR On-Premises Runtime

La funzione `helpdesk-ticket-processor` è ora parte del data plane on-prem. Durante il funzionamento normale l'Helpdesk invoca AWS Lambda sul primary cloud; dopo la promozione DR lo stesso use case viene inoltrato a `event-adapter` e al runtime RIE Kubernetes. La simulazione AWS via LocalStack per il primary cloud è stata rimossa, vedi i limiti dichiarati in [`../RUNBOOK_SCENARIO_REALE.md`](../RUNBOOK_SCENARIO_REALE.md).

This module demonstrates an AWS Lambda compatible execution path for Disaster Recovery on proprietary infrastructure.

## Architecture

- `lambda-image/`: universal Lambda container image. On AWS it delegates to `/lambda-entrypoint.sh`; on-premises it wraps the same entrypoint with `aws-lambda-rie`.
- `kubernetes/helpdesk-ticket-processor.yaml`: the DR side of the function invoked from the dashboard. Its ConfigMap is a **generated copy** of `automazione/apps/functions/ticket-processor/handler.py` — never edit the inline code by hand, run `python automazione/apps/functions/ticket-processor/sync-onprem-configmap.py` instead. `automazione/tests/deployment-contract.ps1` fails when the two copies diverge. See that function's README for the full request path.
- `event-adapter/`: FastAPI middleware that converts generic HTTP traffic into an API Gateway Proxy Integration event and invokes the RIE endpoint.
- `docker-compose.yml`: hardened local orchestration with read-only roots, `/tmp` tmpfs, memory limits, dropped capabilities, and file-based secrets.
- `kubernetes/`: Kubernetes data-plane example. The adapter stays online and resolves functions by service name, while each Lambda function runs in its own isolated Deployment.

## Run

Create placeholder secrets before starting the stack:

```powershell
New-Item -ItemType Directory -Force automazione\lambda-dr\secrets
Set-Content automazione\lambda-dr\secrets\aws_access_key_id "local-access-key"
Set-Content automazione\lambda-dr\secrets\aws_secret_access_key "local-secret-key"
docker compose -f automazione\lambda-dr\docker-compose.yml up --build
```

Invoke through the adapter:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8088/orders/123?source=dr -Body '{"ok":true}' -ContentType 'application/json'
```

## Production Notes

The adapter is intentionally separate from the Lambda runtime. This preserves zero code changes for Lambda handlers and lets the routing layer evolve independently for API Gateway, SQS, EventBridge, or custom enterprise ingress.

For production, replace Compose file secrets with Vault Agent, CSI Secret Store, External Secrets Operator, or a platform-native secret injector. Keep `/tmp` writable because AWS Lambda guarantees it, but keep the root filesystem read-only to catch hidden stateful behavior during DR drills.

## Kubernetes Mode

Build the two local images used by the manifests:

```powershell
docker compose -f automazione\lambda-dr\docker-compose.yml build
```

Apply the Kubernetes data plane:

```powershell
kubectl apply -k automazione\lambda-dr\kubernetes
kubectl -n lambda-dr rollout status deployment/event-adapter
kubectl -n lambda-dr rollout status deployment/lambda-helpdesk-ticket-processor
```

Expose the adapter locally:

```powershell
kubectl -n lambda-dr port-forward svc/event-adapter 8088:8080
```

Invoke the function through the adapter:

```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:8088/2015-03-31/functions/function/invocations" -Body '{"ok":true}' -ContentType "application/json"
```

To add another function, create a new `Deployment` and `Service` named `lambda-<function-name>` in the `lambda-dr` namespace. The adapter resolves it through:

```text
http://lambda-{function_name}.lambda-dr.svc.cluster.local:8080
```

This keeps the Lambda platform online while onboarding new user code as isolated runtime pods.
