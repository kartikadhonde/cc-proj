# Every role here is skipped when use_learner_lab = true (AWS Academy blocks IAM role
# creation); the pre-created LabRole is used for all three ECS roles instead.

locals {
  create_iam = !var.use_learner_lab

  execution_role_arn   = try(aws_iam_role.ecs_execution[0].arn, data.aws_iam_role.lab[0].arn)
  api_task_role_arn    = try(aws_iam_role.api_task[0].arn, data.aws_iam_role.lab[0].arn)
  worker_task_role_arn = try(aws_iam_role.worker_task[0].arn, data.aws_iam_role.lab[0].arn)
}

data "aws_iam_role" "lab" {
  count = var.use_learner_lab ? 1 : 0
  name  = "LabRole"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- ECS execution role: pull images from ECR, write logs ---

resource "aws_iam_role" "ecs_execution" {
  count = local.create_iam ? 1 : 0

  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  count = local.create_iam ? 1 : 0

  role       = aws_iam_role.ecs_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- API task role: DynamoDB CRUD + presigning PUTs to uploads/raw/* ---

resource "aws_iam_role" "api_task" {
  count = local.create_iam ? 1 : 0

  name               = "${local.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "api_task" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.videos.arn]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/raw/*"]
  }
}

resource "aws_iam_role_policy" "api_task" {
  count = local.create_iam ? 1 : 0

  name   = "api-task"
  role   = aws_iam_role.api_task[0].id
  policy = data.aws_iam_policy_document.api_task.json
}

# --- Worker task role: consume SQS, read raw, write processed, update status ---

resource "aws_iam_role" "worker_task" {
  count = local.create_iam ? 1 : 0

  name               = "${local.name}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "worker_task" {
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }

  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.videos.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/raw/*"]
  }

  statement {
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.this["processed"].arn}/processed/*",
      "${aws_s3_bucket.this["processed"].arn}/thumbnails/*",
    ]
  }
}

resource "aws_iam_role_policy" "worker_task" {
  count = local.create_iam ? 1 : 0

  name   = "worker-task"
  role   = aws_iam_role.worker_task[0].id
  policy = data.aws_iam_policy_document.worker_task.json
}

# --- GitHub Actions: OIDC federation, no long-lived keys in GitHub ---

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_iam ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "github_assume" {
  count = local.create_iam ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any branch, PR or workflow in this one repository; nothing else.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count = local.create_iam ? 1 : 0

  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json
}

data "aws_iam_policy_document" "github_deploy" {
  count = local.create_iam ? 1 : 0

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid = "EcsDeploy"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
      "ecs:UpdateService",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "PassTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_execution[0].arn,
      aws_iam_role.api_task[0].arn,
      aws_iam_role.worker_task[0].arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "FrontendSync"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.this["frontend"].arn, "${aws_s3_bucket.this["frontend"].arn}/*"]
  }

  statement {
    sid       = "CloudFrontInvalidate"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.main.arn]
  }

  statement {
    sid = "Discovery"
    actions = [
      "cloudfront:ListDistributions",
      "elasticloadbalancing:DescribeLoadBalancers",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.tf_state_bucket == "" ? [] : [var.tf_state_bucket]
    content {
      sid       = "TerraformState"
      actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["arn:aws:s3:::${statement.value}", "arn:aws:s3:::${statement.value}/*"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.create_iam ? 1 : 0

  name   = "deploy"
  role   = aws_iam_role.github_actions[0].id
  policy = data.aws_iam_policy_document.github_deploy[0].json
}

# Read-only access so the infra.yml workflow can run `terraform plan` on pull requests.
resource "aws_iam_role_policy_attachment" "github_readonly" {
  count = local.create_iam ? 1 : 0

  role       = aws_iam_role.github_actions[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
