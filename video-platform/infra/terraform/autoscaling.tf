# Auto-Scaling: scales worker tasks from 0 to 3 based on SQS queue backlog
#   - Scale Out: >= 1 visible message for 1 minute -> adds 1 to 3 workers
#   - Scale In:  0 visible AND 0 in-flight messages for 5 minutes -> scales back to 0 workers
# Counting in-flight messages ensures workers finish current encoding before stopping.

# Register worker ECS service as a scalable target (min: 0, max: 3)
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = var.worker_max_count
}

# Step Scaling Policy (Scale Out): launches more worker containers as queue grows
resource "aws_appautoscaling_policy" "worker_scale_out" {
  name               = "${local.name}-worker-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Maximum"

    # Step 1: 1 to 4 pending messages -> add 1 worker
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 4
      scaling_adjustment          = 1
    }
    # Step 2: 4 to 9 pending messages -> add 2 workers
    step_adjustment {
      metric_interval_lower_bound = 4
      metric_interval_upper_bound = 9
      scaling_adjustment          = 2
    }
    # Step 3: 9+ pending messages -> add 3 workers
    step_adjustment {
      metric_interval_lower_bound = 9
      scaling_adjustment          = 3
    }
  }
}

# Scale In Policy: shuts down all worker tasks to reach 0 when all jobs are complete
resource "aws_appautoscaling_policy" "worker_scale_in" {
  name               = "${local.name}-worker-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    # Set capacity to 0 tasks
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 0
    }
  }
}

# CloudWatch Alarm: detects pending jobs in SQS and triggers scale-out
resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  alarm_name          = "${local.name}-queue-backlog"
  alarm_description   = "Messages waiting in video-jobs: scale workers out"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.jobs.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.worker_scale_out.arn]
}

# CloudWatch Alarm: detects when queue is empty for 5 minutes and triggers scale to zero
resource "aws_cloudwatch_metric_alarm" "queue_empty" {
  alarm_name          = "${local.name}-queue-empty"
  alarm_description   = "No visible or in-flight jobs for 5 minutes: scale workers to zero"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  evaluation_periods  = 5
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_appautoscaling_policy.worker_scale_in.arn]

  # Composite metric: visible (queued) + in-flight (currently encoding)
  metric_query {
    id          = "total"
    expression  = "visible + inflight"
    label       = "Total jobs"
    return_data = true
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
      stat        = "Maximum"
      period      = 60
    }
  }
}

# --- Operational alerts via SNS ---

# SNS topic for sending failure alerts (e.g. to admin email)
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alert: fires if any video fails 3 times and is diverted to the Dead-Letter Queue
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name}-dlq-not-empty"
  alarm_description   = "A video failed 3 times and landed in the DLQ"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Alert: fires if the backend API generates more than 5 server 5xx errors in 5 minutes
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "API returned more than 5 server errors in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
