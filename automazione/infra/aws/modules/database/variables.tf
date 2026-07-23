variable "name_prefix" {
  type = string
}

variable "database_name" {
  type = string
}

variable "master_username" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "allocated_storage_gib" {
  type = number
}

variable "max_allocated_storage_gib" {
  type = number
}

variable "backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "skip_final_snapshot" {
  type = bool
}

variable "primary_availability_zone" {
  type = string
}

variable "subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An RDS DB subnet group requires subnets in at least two availability zones."
  }
}

variable "vpc_id" {
  type = string
}

variable "application_security_group_id" {
  type = string
}
