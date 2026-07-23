output "backup_bucket_name" {
  value = aws_s3_bucket.backup.id
}

output "backup_bucket_arn" {
  value = aws_s3_bucket.backup.arn
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.id
}

output "frontend_bucket_arn" {
  value = aws_s3_bucket.frontend.arn
}

output "cloudfront_distribution_id" {
  value = try(aws_cloudfront_distribution.frontend[0].id, null)
}

output "cloudfront_distribution_arn" {
  value = try(aws_cloudfront_distribution.frontend[0].arn, null)
}

output "cloudfront_domain_name" {
  value = try(aws_cloudfront_distribution.frontend[0].domain_name, null)
}
