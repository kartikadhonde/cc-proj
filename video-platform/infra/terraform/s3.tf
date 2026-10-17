# Bucket names include the account ID so they are globally unique but stable across
# destroy/apply cycles. force_destroy lets `terraform destroy` empty them.

locals {
  buckets = {
    uploads   = "${local.name}-uploads-${local.account_id}"
    processed = "${local.name}-processed-${local.account_id}"
    frontend  = "${local.name}-frontend-${local.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- uploads: browser PUTs via presigned URL, expires raw files, notifies SQS ---

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  cors_rule {
    allowed_origins = ["*"]
    allowed_methods = ["PUT"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    expiration {
      days = var.raw_upload_expiry_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  queue {
    queue_arn     = aws_sqs_queue.jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".mp4"
  }

  # S3 validates it can publish to the queue when the notification is created.
  depends_on = [aws_sqs_queue_policy.jobs]
}

# --- processed + frontend: private, readable only by this CloudFront distribution ---

data "aws_iam_policy_document" "cloudfront_read" {
  for_each = toset(["processed", "frontend"])

  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this[each.key].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudfront_read" {
  for_each = data.aws_iam_policy_document.cloudfront_read

  bucket = aws_s3_bucket.this[each.key].id
  policy = each.value.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
