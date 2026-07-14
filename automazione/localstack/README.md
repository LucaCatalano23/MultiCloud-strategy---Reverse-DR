# AWS cloud simulation with LocalStack

This module supplies the AWS-facing control plane for the Reverse DR lab:

- `cloud-k3s` provides an EKS-like Kubernetes data plane without requiring the
  Ultimate-only LocalStack EKS API;
- S3 stores versioned PostgreSQL backups;
- Lambda runs `helpdesk-ticket-processor` during normal cloud operation;
- EC2/IAM resources model the VPC, two availability zones, and service roles.

LocalStack's EKS API requires an Ultimate entitlement. The default mode keeps
that API disabled and uses LocalStack for S3, Lambda, IAM, EC2, and STS. Export
the token before starting it:

Run Docker Engine natively in the same Ubuntu WSL distribution that hosts LXD;
Docker Desktop runs in a separate WSL distribution and is not supported by this
topology. Installation commands and checks are in step 0 of
[`RUNBOOK_SCENARIO_REALE.md`](../RUNBOOK_SCENARIO_REALE.md).

```bash
read -rsp 'LocalStack Auth Token: ' LOCALSTACK_AUTH_TOKEN
printf '\n'
export LOCALSTACK_AUTH_TOKEN
cd automazione/localstack
bash scripts/start.sh
```

The real token starts with `ls-`. Reading it silently keeps the secret out of
shell history; never commit it to the repository.

`setup-cloud-sim.sh` must run first because it creates the EKS-like cloud k3s
data plane. It also exports an X509 kubeconfig that is used when the optional
LocalStack EKS API is enabled.

`start.sh` uses an isolated Docker CLI configuration under `.state/docker-config`
unless `DOCKER_CONFIG` is already set. This prevents stale Docker Desktop
credential helpers from affecting the lab without modifying the user's global
Docker configuration.

Verify the simulated AWS resources:

```bash
docker compose exec localstack awslocal s3 ls s3://reverse-dr-helpdesk-backups
docker compose exec localstack awslocal lambda get-function --function-name helpdesk-ticket-processor
```

With a LocalStack Ultimate license, enable and verify the optional EKS API:

```bash
export LOCALSTACK_EKS_API_ENABLED=true
bash scripts/start.sh
docker compose exec localstack awslocal eks describe-cluster --name helpdesk-cloud
```

LocalStack binds its gateway to all host interfaces so the isolated LXD nodes can reach it through the `lxdbr0` gateway. This is appropriate only for the local lab; on a shared host, apply a host firewall rule or bind the service to a dedicated lab interface.
