$ErrorActionPreference = 'Stop'

$terraformRoot = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
  'versions.tf',
  'providers.tf',
  'variables.tf',
  'main.tf',
  'outputs.tf',
  'terraform.tfvars.example',
  'README.md',
  'modules/network/main.tf',
  'modules/eks/main.tf',
  'modules/ecr/main.tf',
  'modules/database/main.tf',
  'modules/storage_edge/main.tf',
  'modules/automation/main.tf',
  'modules/workload_identity/main.tf'
)

$missingFiles = @(
  foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $terraformRoot $relativePath))) {
      $relativePath
    }
  }
)

if ($missingFiles.Count -gt 0) {
  throw "Missing Terraform contract files: $($missingFiles -join ', ')"
}

$terraformSource = Get-ChildItem -LiteralPath $terraformRoot -Filter '*.tf' -File -Recurse |
  ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
  Out-String

$requiredPatterns = [ordered]@{
  'EKS managed node group'       = 'resource\s+"aws_eks_node_group"'
  'RDS managed password'         = 'manage_master_user_password\s*=\s*true'
  'RDS single AZ'                = 'multi_az\s*=\s*false'
  'ECR immutable tags'           = 'image_tag_mutability\s*=\s*"IMMUTABLE"'
  'Private S3 public block'      = 'resource\s+"aws_s3_bucket_public_access_block"'
  'CloudFront OAC'               = 'resource\s+"aws_cloudfront_origin_access_control"'
  'EventBridge bus'              = 'resource\s+"aws_cloudwatch_event_bus"'
  'SQS dead-letter queue'        = 'resource\s+"aws_sqs_queue"\s+"dead_letter"'
  'IRSA OIDC provider'           = 'resource\s+"aws_iam_openid_connect_provider"'
  'No public SSH ingress'        = 'http_tokens\s*=\s*"required"'
  'TLS-only S3 policy'           = 'aws:SecureTransport'
  'Shared tagging'               = 'default_tags'
}

$failedChecks = @(
  foreach ($entry in $requiredPatterns.GetEnumerator()) {
    if ($terraformSource -notmatch $entry.Value) {
      $entry.Key
    }
  }
)

if ($failedChecks.Count -gt 0) {
  throw "Terraform static contract checks failed: $($failedChecks -join ', ')"
}

$forbiddenPatterns = [ordered]@{
  'Hard-coded AWS access key' = 'AKIA[0-9A-Z]{16}'
  'Inline database password'  = '(?im)^\s*(password|master_password)\s*=\s*"[^"$]+'
  'Open EKS API endpoint'     = 'public_access_cidrs\s*=\s*\[\s*"0\.0\.0\.0/0"'
}

$securityFailures = @(
  foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
    if ($terraformSource -match $entry.Value) {
      $entry.Key
    }
  }
)

if ($securityFailures.Count -gt 0) {
  throw "Terraform security checks failed: $($securityFailures -join ', ')"
}

$kubernetesSource = Get-ChildItem -LiteralPath (Join-Path $terraformRoot 'kubernetes') -Filter '*.yaml' -File |
  ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
  Out-String

$kubernetesPatterns = [ordered]@{
  'Canonical BFF API route' = 'path:\s*/api[\r\n]+\s*pathType:\s*Prefix'
  'Canonical web route'     = 'name:\s*helios-web[\r\n]+\s*port:[\r\n]+\s*number:\s*8080'
  'External Secrets'        = 'kind:\s*ExternalSecret'
  'RDS-to-S3 CronJob'       = 'kind:\s*CronJob[\s\S]*pg_dump[\s\S]*aws s3 cp'
  'IRSA annotations'        = 'eks\.amazonaws\.com/role-arn'
}

$kubernetesFailures = @(
  foreach ($entry in $kubernetesPatterns.GetEnumerator()) {
    if ($kubernetesSource -notmatch $entry.Value) {
      $entry.Key
    }
  }
)

if ($kubernetesFailures.Count -gt 0) {
  throw "Kubernetes static contract checks failed: $($kubernetesFailures -join ', ')"
}

Write-Output 'Terraform static contract checks passed.'
