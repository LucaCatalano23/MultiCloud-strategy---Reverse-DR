output "role_arns" {
  value = { for workload, role in aws_iam_role.workload : workload => role.arn }
}

output "service_accounts" {
  value = local.service_accounts
}

output "namespace" {
  value = local.namespace
}
