# Lambda DR On-Premises Runtime

This module demonstrates an AWS Lambda compatible execution path for Disaster Recovery on proprietary infrastructure.

## Architecture

- `lambda-image/`: universal Lambda container image. On AWS it delegates to `/lambda-entrypoint.sh`; on-premises it wraps the same entrypoint with `aws-lambda-rie`.
- `event-adapter/`: FastAPI middleware that converts generic HTTP traffic into an API Gateway Proxy Integration event and invokes the RIE endpoint.
- `docker-compose.yml`: hardened local orchestration with read-only roots, `/tmp` tmpfs, memory limits, dropped capabilities, and file-based secrets.

## Run

Create placeholder secrets before starting the stack:

```powershell
New-Item -ItemType Directory -Force automazione\lambda-dr\secrets
Set-Content automazione\lambda-dr\secrets\aws_access_key_id "local-access-key"
Set-Content automazione\lambda-dr\secrets\aws_secret_access_key "local-secret-key"
docker compose -f automazione\lambda-dr\docker-compose.lambda-dr.yml up --build
docker compose -f automazione\lambda-dr\docker-compose.yml up --build
```

Invoke through the adapter:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8088/orders/123?source=dr -Body '{"ok":true}' -ContentType 'application/json'
```

## Production Notes

The adapter is intentionally separate from the Lambda runtime. This preserves zero code changes for Lambda handlers and lets the routing layer evolve independently for API Gateway, SQS, EventBridge, or custom enterprise ingress.

For production, replace Compose file secrets with Vault Agent, CSI Secret Store, External Secrets Operator, or a platform-native secret injector. Keep `/tmp` writable because AWS Lambda guarantees it, but keep the root filesystem read-only to catch hidden stateful behavior during DR drills.
