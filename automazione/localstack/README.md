# AWS cloud simulation with LocalStack

This module supplies the AWS-facing control plane for the Reverse DR lab:

- LocalStack EKS registers the existing `cloud-k3s` Kubernetes data plane;
- S3 stores versioned PostgreSQL backups;
- Lambda runs `helpdesk-ticket-processor` during normal cloud operation;
- EC2/IAM resources model the VPC, two availability zones, and service roles.

LocalStack EKS requires an Ultimate, Enterprise, or Student entitlement. Export the token before starting it:

```bash
export LOCALSTACK_AUTH_TOKEN='<token>'
cd automazione/localstack
bash scripts/start.sh
```

`setup-cloud-sim.sh` must run first because it exports the X509 k3s kubeconfig consumed by `EKS_K8S_PROVIDER=local`.

Verify the simulated AWS resources:

```bash
docker compose exec localstack awslocal eks describe-cluster --name helpdesk-cloud
docker compose exec localstack awslocal s3 ls s3://reverse-dr-helpdesk-backups
docker compose exec localstack awslocal lambda get-function --function-name helpdesk-ticket-processor
```

LocalStack binds its gateway to all host interfaces so the isolated LXD nodes can reach it through the `lxdbr0` gateway. This is appropriate only for the local lab; on a shared host, apply a host firewall rule or bind the service to a dedicated lab interface.
