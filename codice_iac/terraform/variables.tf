variable "aws_region" {
  description = "Regione AWS di produzione."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Prefisso usato per nominare le risorse."
  type        = string
  default     = "reverse-dr-poc"
}

variable "environment" {
  description = "Nome dell'ambiente."
  type        = string
  default     = "production"
}

variable "bucket_name" {
  description = "Nome S3 globalmente univoco."
  type        = string
}

variable "database_name" {
  description = "Database applicativo iniziale."
  type        = string
  default     = "reversedr"
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]+$", var.database_name))
    error_message = "database_name deve iniziare con una lettera e contenere solo caratteri alfanumerici o underscore."
  }
}

variable "database_username" {
  description = "Utente amministrativo RDS."
  type        = string
  default     = "reversedr"
}

variable "database_password" {
  description = "Password RDS; fornire tramite TF_VAR_database_password."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.database_password) >= 16
    error_message = "La password RDS deve contenere almeno 16 caratteri."
  }
}

variable "db_instance_class" {
  description = "Classe low-cost per la PoC."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Storage PostgreSQL in GiB."
  type        = number
  default     = 20
}

variable "db_publicly_accessible" {
  description = "Espone RDS su Internet. Lasciare false salvo test controllati."
  type        = bool
  default     = false
}

variable "db_allowed_cidrs" {
  description = "CIDR autorizzati a PostgreSQL quando l'accesso pubblico è abilitato."
  type        = list(string)
  default     = []
}

