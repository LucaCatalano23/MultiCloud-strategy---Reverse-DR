module "network" {
  source = "./modules/network"

  name_prefix                 = local.name_prefix
  vpc_cidr                    = var.vpc_cidr
  primary_availability_zone   = local.selected_availability_zones[0]
  witness_availability_zone   = local.selected_availability_zones[1]
  primary_public_subnet_cidr  = var.primary_public_subnet_cidr
  witness_public_subnet_cidr  = var.witness_public_subnet_cidr
  primary_private_subnet_cidr = var.primary_private_subnet_cidr
  witness_private_subnet_cidr = var.witness_private_subnet_cidr
  nat_instance_type           = var.nat_instance_type
  nat_ami_id                  = var.nat_ami_id
  enable_vpc_flow_logs        = var.enable_vpc_flow_logs
  log_retention_days          = var.log_retention_days
}

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
}

module "eks" {
  source = "./modules/eks"

  name_prefix                    = local.name_prefix
  aws_partition                  = data.aws_partition.current.partition
  aws_region                     = var.aws_region
  vpc_id                         = module.network.vpc_id
  vpc_arn                        = module.network.vpc_arn
  cluster_subnet_ids             = module.network.eks_cluster_subnet_ids
  node_subnet_ids                = [module.network.primary_private_subnet_id]
  kubernetes_version             = var.kubernetes_version
  endpoint_public_access         = var.eks_endpoint_public_access
  public_access_cidrs            = var.eks_public_access_cidrs
  admin_principal_arns           = var.eks_admin_principal_arns
  node_instance_types            = var.eks_node_instance_types
  node_capacity_type             = var.eks_node_capacity_type
  node_min_size                  = var.eks_node_min_size
  node_desired_size              = var.eks_node_desired_size
  node_max_size                  = var.eks_node_max_size
  node_disk_size_gib             = var.eks_node_disk_size_gib
  control_plane_log_types        = ["api", "audit", "authenticator"]
  log_retention_days             = var.log_retention_days
}

module "database" {
  source = "./modules/database"

  name_prefix                  = local.name_prefix
  database_name                = var.database_name
  master_username              = var.database_master_username
  engine_version               = var.database_engine_version
  instance_class               = var.database_instance_class
  allocated_storage_gib        = var.database_allocated_storage_gib
  max_allocated_storage_gib    = var.database_max_allocated_storage_gib
  backup_retention_days        = var.database_backup_retention_days
  deletion_protection          = var.database_deletion_protection
  skip_final_snapshot          = var.database_skip_final_snapshot
  primary_availability_zone    = local.selected_availability_zones[0]
  subnet_ids                   = module.network.eks_cluster_subnet_ids
  vpc_id                       = module.network.vpc_id
  application_security_group_id = module.eks.cluster_security_group_id
}

module "storage_edge" {
  source = "./modules/storage_edge"

  name_prefix         = local.name_prefix
  account_id          = data.aws_caller_identity.current.account_id
  aws_region          = var.aws_region
  force_destroy       = var.bucket_force_destroy
  enable_cloudfront   = var.enable_cloudfront_frontend
  cloudfront_aliases  = var.cloudfront_aliases
  acm_certificate_arn = var.cloudfront_acm_certificate_arn
  price_class         = var.cloudfront_price_class
}

module "automation" {
  source = "./modules/automation"

  name_prefix         = local.name_prefix
  lambda_image_uri    = var.automation_lambda_image_uri
  lambda_architecture = var.automation_lambda_architecture
  application_secret_arns = [
    module.database.application_config_secret_arn,
    module.database.application_database_secret_arn,
  ]
  log_retention_days = var.log_retention_days
}

module "workload_identity" {
  source = "./modules/workload_identity"

  name_prefix                     = local.name_prefix
  oidc_provider_arn               = module.eks.oidc_provider_arn
  oidc_issuer_url                 = module.eks.oidc_issuer_url
  application_config_secret_arn   = module.database.application_config_secret_arn
  application_database_secret_arn = module.database.application_database_secret_arn
  backup_bucket_arn               = module.storage_edge.backup_bucket_arn
  event_bus_arn                   = module.automation.event_bus_arn
  automation_queue_arn            = module.automation.queue_arn
  automation_lambda_function_arn  = module.automation.lambda_function_arn
}
