variable "name_prefix" {
  type = string
}

variable "aws_partition" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_arn" {
  type = string
}

variable "cluster_subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.cluster_subnet_ids) >= 2
    error_message = "EKS requires at least two cluster subnets in distinct availability zones."
  }
}

variable "node_subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.node_subnet_ids) == 1
    error_message = "This PoC intentionally pins its node group to exactly one primary-AZ subnet."
  }
}

variable "kubernetes_version" {
  type     = string
  default  = null
  nullable = true
}

variable "endpoint_public_access" {
  type = bool
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "admin_principal_arns" {
  type = set(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_capacity_type" {
  type = string
}

variable "node_min_size" {
  type = number
}

variable "node_desired_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_disk_size_gib" {
  type = number
}

variable "control_plane_log_types" {
  type = list(string)
}

variable "log_retention_days" {
  type = number
}
