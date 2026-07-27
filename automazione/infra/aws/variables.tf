variable "aws_region" {
  description = "AWS region for the primary PoC."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier."
  }
}

variable "project_name" {
  description = "Stable project identifier used in names and tags."
  type        = string
  default     = "reverse-dr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-22 lowercase alphanumeric or hyphen characters."
  }
}

variable "environment" {
  description = "Deployment environment identifier."
  type        = string
  default     = "poc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}[a-z0-9]$", var.environment))
    error_message = "environment must be 3-12 lowercase alphanumeric or hyphen characters."
  }
}

variable "availability_zones" {
  description = "Optional ordered [primary, witness] AZ list. Empty selects the first two available AZs."
  type        = list(string)
  default     = []

  validation {
    condition = (
      length(var.availability_zones) == 0 ||
      (length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2)
    )
    error_message = "availability_zones must be empty or contain two distinct AZs: primary then witness."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "primary_public_subnet_cidr" {
  description = "Public subnet CIDR in the primary workload AZ."
  type        = string
  default     = "10.42.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.primary_public_subnet_cidr))
    error_message = "primary_public_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "witness_public_subnet_cidr" {
  description = "Public /27-or-larger subnet CIDR in the witness AZ, used only by ALB."
  type        = string
  default     = "10.42.1.0/27"

  validation {
    condition     = can(cidrnetmask(var.witness_public_subnet_cidr)) && tonumber(split("/", var.witness_public_subnet_cidr)[1]) <= 27
    error_message = "witness_public_subnet_cidr must be a valid IPv4 CIDR with /27 or more addresses."
  }
}

variable "primary_private_subnet_cidr" {
  description = "Private subnet CIDR for nodes, pods and RDS in the primary AZ."
  type        = string
  default     = "10.42.10.0/24"

  validation {
    condition     = can(cidrnetmask(var.primary_private_subnet_cidr))
    error_message = "primary_private_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "witness_private_subnet_cidr" {
  description = "Minimal private subnet CIDR in the witness AZ for EKS ENIs and the RDS subnet group."
  type        = string
  default     = "10.42.11.0/28"

  validation {
    condition     = can(cidrnetmask(var.witness_private_subnet_cidr)) && tonumber(split("/", var.witness_private_subnet_cidr)[1]) <= 28
    error_message = "witness_private_subnet_cidr must be a valid IPv4 CIDR with /28 or more addresses."
  }
}

variable "nat_instance_type" {
  description = "Small ARM instance used as the PoC NAT instead of a billed-per-hour NAT Gateway."
  type        = string
  default     = "t4g.nano"
}

variable "nat_ami_id" {
  description = "Optional trusted ARM64 NAT AMI. Null selects the latest Amazon Linux 2023 ARM64 AMI."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.nat_ami_id == null || can(regex("^ami-[0-9a-f]+$", var.nat_ami_id))
    error_message = "nat_ami_id must be null or a valid AMI ID."
  }
}

variable "kubernetes_version" {
  description = "Optional EKS Kubernetes minor version. Null lets AWS select its current default."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.kubernetes_version == null || can(regex("^1[.][0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be null or a minor version such as 1.32."
  }
}

variable "eks_endpoint_public_access" {
  description = "Expose the EKS API endpoint to explicitly allow-listed public CIDRs."
  type        = bool
  default     = false
}

variable "eks_public_access_cidrs" {
  description = "Operator CIDRs for the optional public EKS endpoint. World-open CIDRs are rejected."
  type        = list(string)
  default     = ["203.0.113.10/32"]

  validation {
    condition = alltrue([
      for cidr in var.eks_public_access_cidrs :
      can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Every EKS public access CIDR must be valid and neither IPv4 nor IPv6 world-open."
  }
}

variable "eks_admin_principal_arns" {
  description = "IAM user/role ARNs granted explicit EKS cluster-admin access. Empty grants no human access."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.eks_admin_principal_arns : can(regex("^arn:[^:]+:iam::[0-9]{12}:(role|user)/", arn))])
    error_message = "Each EKS administrator must be an IAM role or user ARN."
  }
}

variable "eks_node_instance_types" {
  description = "EC2 instance types allowed for the primary managed node group."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.eks_node_instance_types) > 0
    error_message = "At least one EKS node instance type is required."
  }
}

variable "eks_node_capacity_type" {
  description = "Managed node group purchasing model."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.eks_node_capacity_type)
    error_message = "eks_node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "eks_node_min_size" {
  description = "Minimum number of EC2 worker nodes in the primary AZ."
  type        = number
  default     = 1
}

variable "eks_node_desired_size" {
  description = "Desired number of EC2 worker nodes in the primary AZ."
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of EC2 worker nodes in the primary AZ."
  type        = number
  default     = 2
}

variable "eks_node_disk_size_gib" {
  description = "Encrypted gp3 root volume size for every managed node."
  type        = number
  default     = 30

  validation {
    condition     = var.eks_node_disk_size_gib >= 20 && var.eks_node_disk_size_gib <= 200
    error_message = "eks_node_disk_size_gib must be between 20 and 200 GiB."
  }
}

variable "database_name" {
  # Database applicativo Helios. Coerente con il sito DR, dove HELIOS_DATABASE_URL
  # e restore-onprem.sh usano lo stesso database `helios`, distinto dal database
  # legacy `helpdesk` del monolite rimosso (vedi CLAUDE.md sezione 1).
  description = "Initial PostgreSQL database name (Helios application database)."
  type        = string
  default     = "helios"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be a valid lowercase PostgreSQL identifier."
  }
}

variable "database_master_username" {
  description = "RDS bootstrap username; its password is generated and stored by RDS in Secrets Manager."
  type        = string
  default     = "platform_admin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_master_username))
    error_message = "database_master_username must be a valid lowercase PostgreSQL identifier."
  }
}

variable "database_instance_class" {
  description = "Single-AZ RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "database_engine_version" {
  description = "PostgreSQL major version. AWS selects and auto-upgrades the compatible minor release."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.database_engine_version))
    error_message = "database_engine_version must be a PostgreSQL major version such as 16."
  }
}

variable "database_allocated_storage_gib" {
  description = "Initial encrypted gp3 storage size."
  type        = number
  default     = 20

  validation {
    condition     = var.database_allocated_storage_gib >= 20
    error_message = "database_allocated_storage_gib must be at least 20 GiB for gp3."
  }
}

variable "database_max_allocated_storage_gib" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 100

  validation {
    condition     = var.database_max_allocated_storage_gib >= 20
    error_message = "database_max_allocated_storage_gib must be at least 20 GiB."
  }
}

variable "database_backup_retention_days" {
  description = "RDS automated backup retention."
  type        = number
  default     = 7

  validation {
    condition     = var.database_backup_retention_days >= 1 && var.database_backup_retention_days <= 35
    error_message = "database_backup_retention_days must be between 1 and 35."
  }
}

variable "database_deletion_protection" {
  description = "Protect RDS from deletion. Enable outside ephemeral PoC environments."
  type        = bool
  default     = false
}

variable "database_skip_final_snapshot" {
  description = "Skip the final RDS snapshot on destroy. True keeps PoC teardown predictable."
  type        = bool
  default     = true
}

variable "bucket_force_destroy" {
  description = "Allow Terraform to delete non-empty PoC buckets. Keep false for recoverability."
  type        = bool
  default     = false
}

variable "cloudfront_aliases" {
  description = "Optional custom frontend hostnames."
  type        = list(string)
  default     = []
}

variable "enable_cloudfront_frontend" {
  description = "Enable the static React build/preview distribution. It is not the canonical same-origin application endpoint."
  type        = bool
  default     = false
}

variable "cloudfront_acm_certificate_arn" {
  description = "Optional ACM certificate ARN in us-east-1, required with aliases."
  type        = string
  default     = null
  nullable    = true
}

variable "cloudfront_price_class" {
  description = "CloudFront edge footprint; PriceClass_100 is the cost-conscious default."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "automation_lambda_image_uri" {
  description = "Optional immutable ECR image URI (prefer @sha256 digest) enabling the SQS consumer Lambda."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.automation_lambda_image_uri == null || can(regex("[.]dkr[.]ecr[.].+[.]amazonaws[.]com/.+(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$", var.automation_lambda_image_uri))
    error_message = "automation_lambda_image_uri must be null or a valid ECR image URI."
  }
}

variable "automation_lambda_architecture" {
  description = "CPU architecture expected by the optional Lambda container image."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.automation_lambda_architecture)
    error_message = "automation_lambda_architecture must be x86_64 or arm64."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for EKS, VPC and optional Lambda logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported retention period."
  }
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs. Disabled by default to cap PoC ingestion cost."
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Additional tags merged into every taggable AWS resource."
  type        = map(string)
  default     = {}
}
