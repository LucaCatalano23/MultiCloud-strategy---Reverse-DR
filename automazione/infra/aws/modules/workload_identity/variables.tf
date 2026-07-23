variable "name_prefix" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_issuer_url" {
  type = string
}

variable "application_config_secret_arn" {
  type = string
}

variable "application_database_secret_arn" {
  type = string
}

variable "backup_bucket_arn" {
  type = string
}

variable "event_bus_arn" {
  type = string
}

variable "automation_queue_arn" {
  type = string
}

variable "automation_lambda_function_arn" {
  type     = string
  default  = null
  nullable = true
}
