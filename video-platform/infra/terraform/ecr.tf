# Amazon ECR Repositories: stores Docker container images for API and Worker
resource "aws_ecr_repository" "this" {
  for_each = toset(["api", "worker"])

  name = "${local.name}-${each.key}"
  # MUTABLE allows CI/CD to update the `latest` tag; deployments are pinned to commit SHA
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # Security: automatically scan container images for vulnerabilities upon push
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lifecycle Policy: keeps only the 5 newest container images to save storage costs
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
