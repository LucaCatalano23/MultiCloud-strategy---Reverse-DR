output "repository_urls" {
  value = { for service, repository in aws_ecr_repository.service : service => repository.repository_url }
}

output "repository_arns" {
  value = { for service, repository in aws_ecr_repository.service : service => repository.arn }
}

output "repository_names" {
  value = { for service, repository in aws_ecr_repository.service : service => repository.name }
}
