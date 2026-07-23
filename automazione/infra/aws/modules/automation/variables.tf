variable "name_prefix" {
  type = string
}

variable "lambda_image_uri" {
  type     = string
  default  = null
  nullable = true
}

variable "lambda_architecture" {
  type = string
}

variable "application_secret_arns" {
  type = list(string)
}

variable "log_retention_days" {
  type = number
}
