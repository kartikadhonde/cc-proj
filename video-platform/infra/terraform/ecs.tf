# ECS Cluster: manages running container tasks on serverless AWS Fargate
resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # extra CloudWatch cost; enable for deeper metrics
  }
}

# Capacity providers: FARGATE (on-demand) and FARGATE_SPOT (up to 70% cheaper spare compute)
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# CloudWatch log groups: stores application logs for 7 days
resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(["api", "worker"])

  name              = "/ecs/${local.name}-${each.key}"
  retention_in_days = 7
}

# --- Application Load Balancer (ALB) ---

# Public load balancer: receives HTTP requests from CloudFront and routes them to API containers
resource "aws_lb" "api" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

# Target group: registers running API containers and pings /health every 15s
resource "aws_lb_target_group" "api" {
  name                 = "${local.name}-api"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  # Health check probe: fails after 3 bad responses, marks container healthy after 2 good ones
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP listener: listens on port 80 and forwards traffic to the API target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# --- Task definitions ---

locals {
  log_config = {
    for svc in ["api", "worker"] : svc => {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[svc].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = svc
      }
    }
  }
}

# API Task Definition: 0.25 vCPU, 512 MB RAM, runs FastAPI web server
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.api_task_role_arn

  container_definitions = jsonencode([{
    name         = "api"
    image        = "${aws_ecr_repository.this["api"].repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DDB_TABLE", value = aws_dynamodb_table.videos.name },
      { name = "UPLOADS_BUCKET", value = aws_s3_bucket.this["uploads"].id },
      { name = "CLOUDFRONT_DOMAIN", value = aws_cloudfront_distribution.main.domain_name },
    ]
    logConfiguration = local.log_config["api"]
  }])
}

# Worker Task Definition: 1.0 vCPU, 2048 MB RAM, runs FFmpeg multi-rendition transcoder
resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.worker_task_role_arn

  container_definitions = jsonencode([{
    name        = "worker"
    image       = "${aws_ecr_repository.this["worker"].repository_url}:latest"
    essential   = true
    stopTimeout = 120 # Fargate Spot gives a 2-minute warning; let the current job finish
    environment = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
      { name = "DDB_TABLE", value = aws_dynamodb_table.videos.name },
      { name = "UPLOADS_BUCKET", value = aws_s3_bucket.this["uploads"].id },
      { name = "PROCESSED_BUCKET", value = aws_s3_bucket.this["processed"].id },
    ]
    logConfiguration = local.log_config["worker"]
  }])
}

# --- Services ---

# API ECS Service: runs 1 steady container task with automatic rollback on failed health checks
resource "aws_ecs_service" "api" {
  name                              = "${local.name}-api"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = var.api_desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Deployment Circuit Breaker: automatically rolls back to previous version if health checks fail
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http]
}

# Worker ECS Service: runs on Fargate Spot (70% cheaper), scales dynamically from 0 to N tasks
resource "aws_ecs_service" "worker" {
  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 0 # autoscaling.tf scales 0 -> N from queue depth

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}
