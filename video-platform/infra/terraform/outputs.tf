output "cloudfront_url" {
  description = "Open this in your browser: the app (frontend + API + media)."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "alb_dns_name" {
  description = "Direct API endpoint (HTTP). Used by CI smoke tests."
  value       = aws_lb.api.dns_name
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable in GitHub."
  value       = local.create_iam ? aws_iam_role.github_actions[0].arn : null
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.this["uploads"].id
}

output "processed_bucket_name" {
  value = aws_s3_bucket.this["processed"].id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.this["frontend"].id
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
