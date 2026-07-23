output "identifier" {
  value = aws_db_instance.main.identifier
}

output "endpoint" {
  value = aws_db_instance.main.endpoint
}

output "address" {
  value = aws_db_instance.main.address
}

output "port" {
  value = aws_db_instance.main.port
}

output "database_name" {
  value = aws_db_instance.main.db_name
}

output "availability_zone" {
  value = aws_db_instance.main.availability_zone
}

output "multi_az" {
  value = aws_db_instance.main.multi_az
}

output "master_user_secret_arn" {
  value     = aws_db_instance.main.master_user_secret[0].secret_arn
  sensitive = true
}

output "application_database_secret_arn" {
  value = aws_secretsmanager_secret.application_database.arn
}

output "application_config_secret_arn" {
  value = aws_secretsmanager_secret.application_config.arn
}
