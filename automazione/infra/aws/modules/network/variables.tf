variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "primary_availability_zone" {
  type = string
}

variable "witness_availability_zone" {
  type = string
}

variable "primary_public_subnet_cidr" {
  type = string
}

variable "witness_public_subnet_cidr" {
  type = string
}

variable "primary_private_subnet_cidr" {
  type = string
}

variable "witness_private_subnet_cidr" {
  type = string
}

variable "nat_instance_type" {
  type = string
}

variable "nat_ami_id" {
  type     = string
  default  = null
  nullable = true
}

variable "enable_vpc_flow_logs" {
  type = bool
}

variable "log_retention_days" {
  type = number
}
