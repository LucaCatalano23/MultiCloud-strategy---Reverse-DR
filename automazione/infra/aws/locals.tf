locals {
  name_prefix = lower("${var.project_name}-${var.environment}")

  selected_availability_zones = length(var.availability_zones) == 2 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    2,
  )

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "Tesi"
      WorkloadAZ  = local.selected_availability_zones[0]
      Resilience  = "PoC-single-AZ"
    },
    var.common_tags,
  )
}

check "node_group_capacity_is_coherent" {
  assert {
    condition = (
      var.eks_node_min_size <= var.eks_node_desired_size &&
      var.eks_node_desired_size <= var.eks_node_max_size
    )
    error_message = "EKS node sizes must satisfy min <= desired <= max."
  }
}

check "custom_domain_is_complete" {
  assert {
    condition = var.enable_cloudfront_frontend ? (
      (length(var.cloudfront_aliases) == 0) == (var.cloudfront_acm_certificate_arn == null)
    ) : (
      length(var.cloudfront_aliases) == 0 && var.cloudfront_acm_certificate_arn == null
    )
    error_message = "CloudFront aliases and a us-east-1 ACM certificate ARN must be supplied together, and only when CloudFront is enabled."
  }
}

check "database_storage_autoscaling_is_coherent" {
  assert {
    condition     = var.database_max_allocated_storage_gib >= var.database_allocated_storage_gib
    error_message = "database_max_allocated_storage_gib must be at least database_allocated_storage_gib."
  }
}
