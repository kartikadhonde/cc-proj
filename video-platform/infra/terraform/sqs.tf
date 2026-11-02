# Dead-Letter Queue (DLQ): holds failed video conversion jobs for 14 days so they can be inspected and retried
resource "aws_sqs_queue" "dlq" {
  name                      = "video-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# Primary Jobs Queue: buffers new video conversion tasks received from S3 upload events
resource "aws_sqs_queue" "jobs" {
  name                       = "video-jobs"
  visibility_timeout_seconds = 300    # 5 minutes: time given to the worker to finish transcoding
  receive_wait_time_seconds  = 20     # 20s long polling: reduces empty checks and saves API costs
  message_retention_seconds  = 345600 # 4 days

  # Retry policy: if a job fails 3 times, automatically move it to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# Redrive policy: allows moving messages back from DLQ to the main queue after a fix
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}

# Permission document: allows S3 to post video upload notification events into SQS
data "aws_iam_policy_document" "jobs_queue" {
  statement {
    sid       = "AllowUploadsBucket"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.this["uploads"].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Attach permission policy to the primary jobs SQS queue
resource "aws_sqs_queue_policy" "jobs" {
  queue_url = aws_sqs_queue.jobs.id
  policy    = data.aws_iam_policy_document.jobs_queue.json
}
