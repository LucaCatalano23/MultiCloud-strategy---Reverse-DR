#!/usr/bin/env bash
set -euo pipefail

region="${AWS_DEFAULT_REGION:-eu-west-1}"
account_id="000000000000"
bucket="${BACKUP_S3_BUCKET:-reverse-dr-helpdesk-backups}"
cluster_name="${EKS_CLUSTER_NAME:-helpdesk-cloud}"
lambda_name="${HELPDESK_LAMBDA_FUNCTION_NAME:-helpdesk-ticket-processor}"

role_trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["eks.amazonaws.com","lambda.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'

ensure_role() {
  local role_name="$1"
  if ! awslocal iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    awslocal iam create-role \
      --role-name "${role_name}" \
      --assume-role-policy-document "${role_trust_policy}" >/dev/null
  fi
}

ensure_bucket() {
  if ! awslocal s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    awslocal s3api create-bucket \
      --bucket "${bucket}" \
      --create-bucket-configuration "LocationConstraint=${region}" >/dev/null
  fi

  awslocal s3api put-bucket-versioning \
    --bucket "${bucket}" \
    --versioning-configuration Status=Enabled >/dev/null

  awslocal s3api put-bucket-lifecycle-configuration \
    --bucket "${bucket}" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-old-backups","Status":"Enabled","Filter":{"Prefix":"postgres/"},"Expiration":{"Days":7},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}' >/dev/null
}

ensure_network() {
  local vpc_id subnet_a subnet_b
  vpc_id="$(awslocal ec2 describe-vpcs \
    --filters Name=tag:Name,Values=reverse-dr-cloud \
    --query 'Vpcs[0].VpcId' --output text)"
  if [ -z "${vpc_id}" ] || [ "${vpc_id}" = "None" ]; then
    vpc_id="$(awslocal ec2 create-vpc \
      --cidr-block 10.20.0.0/16 \
      --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=reverse-dr-cloud}]' \
      --query 'Vpc.VpcId' --output text)"
  fi

  subnet_a="$(awslocal ec2 describe-subnets \
    --filters Name=vpc-id,Values="${vpc_id}" Name=tag:Name,Values=reverse-dr-eu-west-1a \
    --query 'Subnets[0].SubnetId' --output text)"
  if [ -z "${subnet_a}" ] || [ "${subnet_a}" = "None" ]; then
    subnet_a="$(awslocal ec2 create-subnet \
      --vpc-id "${vpc_id}" --cidr-block 10.20.1.0/24 --availability-zone "${region}a" \
      --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=reverse-dr-eu-west-1a}]' \
      --query 'Subnet.SubnetId' --output text)"
  fi

  subnet_b="$(awslocal ec2 describe-subnets \
    --filters Name=vpc-id,Values="${vpc_id}" Name=tag:Name,Values=reverse-dr-eu-west-1b \
    --query 'Subnets[0].SubnetId' --output text)"
  if [ -z "${subnet_b}" ] || [ "${subnet_b}" = "None" ]; then
    subnet_b="$(awslocal ec2 create-subnet \
      --vpc-id "${vpc_id}" --cidr-block 10.20.2.0/24 --availability-zone "${region}b" \
      --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=reverse-dr-eu-west-1b}]' \
      --query 'Subnet.SubnetId' --output text)"
  fi

  printf '{"subnetIds":["%s","%s"]}\n' "${subnet_a}" "${subnet_b}"
}

ensure_eks_cluster() {
  local vpc_config="$1"
  if ! awslocal eks describe-cluster --name "${cluster_name}" >/dev/null 2>&1; then
    awslocal eks create-cluster \
      --name "${cluster_name}" \
      --role-arn "arn:aws:iam::${account_id}:role/reverse-dr-eks-role" \
      --resources-vpc-config "${vpc_config}" \
      --tags Environment=local,Workload=reverse-dr >/dev/null
  fi
  awslocal eks wait cluster-active --name "${cluster_name}"
}

ensure_lambda() {
  local artifact="/tmp/${lambda_name}.zip"
  python3 - "${artifact}" <<'PY'
import sys
import zipfile

target = sys.argv[1]
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.write(
        "/opt/reverse-dr/functions/ticket_processor.py",
        arcname="ticket_processor.py",
    )
PY

  if awslocal lambda get-function --function-name "${lambda_name}" >/dev/null 2>&1; then
    awslocal lambda update-function-code \
      --function-name "${lambda_name}" \
      --zip-file "fileb://${artifact}" >/dev/null
  else
    awslocal lambda create-function \
      --function-name "${lambda_name}" \
      --runtime python3.12 \
      --handler ticket_processor.handler \
      --timeout 10 \
      --memory-size 256 \
      --role "arn:aws:iam::${account_id}:role/reverse-dr-lambda-role" \
      --zip-file "fileb://${artifact}" \
      --tags Environment=local,Workload=reverse-dr >/dev/null
  fi
  awslocal lambda wait function-active-v2 --function-name "${lambda_name}"
}

ensure_role reverse-dr-eks-role
ensure_role reverse-dr-lambda-role
ensure_bucket
subnets="$(ensure_network)"
ensure_eks_cluster "${subnets}"
ensure_lambda

echo "LocalStack AWS cloud ready: EKS=${cluster_name}, S3=${bucket}, Lambda=${lambda_name}"
