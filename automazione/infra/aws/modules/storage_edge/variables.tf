variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "force_destroy" {
  type = bool
}

variable "enable_cloudfront" {
  type = bool
}

variable "cloudfront_aliases" {
  type = list(string)
}

variable "acm_certificate_arn" {
  type     = string
  default  = null
  nullable = true
}

variable "price_class" {
  type = string
}
