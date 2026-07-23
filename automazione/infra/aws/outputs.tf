output "name_prefix" {
  description = "Canonical prefix used by AWS resources."
  value       = local.name_prefix
}

output "availability_zones" {
  description = "Ordered primary and witness availability zones."
  value = {
    primary = local.selected_availability_zones[0]
    witness = local.selected_availability_zones[1]
  }
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "subnet_ids" {
  description = "Subnets grouped by their deliberately constrained purpose."
  value = {
    primary_public  = module.network.primary_public_subnet_id
    primary_private = module.network.primary_private_subnet_id
    witness_public  = module.network.witness_public_subnet_id
    witness_private = module.network.witness_private_subnet_id
  }
}

output "nat_public_ip" {
  description = "Elastic IP of the self-managed PoC NAT instance."
  value       = module.network.nat_public_ip
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_version" {
  value = module.eks.cluster_version
}

output "eks_node_group_name" {
  value = module.eks.node_group_name
}

output "eks_node_role_arn" {
  value = module.eks.node_role_arn
}

output "eks_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "load_balancer_controller_role_arn" {
  description = "Annotate kube-system/aws-load-balancer-controller with this IRSA role ARN."
  value       = module.eks.load_balancer_controller_role_arn
}

output "ecr_repository_urls" {
  description = "Service-to-ECR repository URL map used by build and deployment pipelines."
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  value = module.ecr.repository_arns
}

output "database_identifier" {
  value = module.database.identifier
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "database_name" {
  value = module.database.database_name
}

output "database_master_secret_arn" {
  description = "RDS-managed bootstrap secret. Runtime workloads are intentionally not authorized to read it."
  value       = module.database.master_user_secret_arn
  sensitive   = true
}

output "application_secret_arns" {
  description = "Empty secret containers whose values must be populated out of band."
  value = {
    config   = module.database.application_config_secret_arn
    database = module.database.application_database_secret_arn
  }
}

output "backup_bucket_name" {
  value = module.storage_edge.backup_bucket_name
}

output "frontend_bucket_name" {
  value = module.storage_edge.frontend_bucket_name
}

output "cloudfront_distribution_id" {
  value = module.storage_edge.cloudfront_distribution_id
}

output "cloudfront_domain_name" {
  value = module.storage_edge.cloudfront_domain_name
}

output "event_bus_name" {
  value = module.automation.event_bus_name
}

output "event_bus_arn" {
  value = module.automation.event_bus_arn
}

output "automation_queue_url" {
  value = module.automation.queue_url
}

output "automation_queue_arn" {
  value = module.automation.queue_arn
}

output "automation_dead_letter_queue_arn" {
  value = module.automation.dead_letter_queue_arn
}

output "automation_lambda_function_arn" {
  description = "Null until automation_lambda_image_uri enables the optional Lambda consumer."
  value       = module.automation.lambda_function_arn
}

output "automation_lambda_function_name" {
  description = "Null until automation_lambda_image_uri enables the optional Lambda consumer."
  value       = module.automation.lambda_function_name
}

output "workload_irsa_role_arns" {
  description = "IRSA roles keyed by Kubernetes workload."
  value       = module.workload_identity.role_arns
}

output "workload_service_accounts" {
  description = "Canonical namespace and service-account contract expected by Kubernetes manifests."
  value = {
    namespace        = module.workload_identity.namespace
    service_accounts = module.workload_identity.service_accounts
  }
}
