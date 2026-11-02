# S3 Storage Buckets:
#   1. uploads   - temporary bucket for raw uploaded MP4 videos
#   2. processed - permanent storage for converted 720p/480p videos and thumbnails
#   3. frontend  - static website hosting (HTML, JS, CSS)

locals {
  buckets = {
    uploads   = "${local.name}-uploads-${local.account_id}"
    processed = "${local.name}-processed-${local.account_id}"
    frontend  = "${local.name}-frontend-${local.account_id}"
  }
}

# Create all three S3 buckets (force_destroy allows clean deletion during teardown)
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = true
}

# Security: block all public internet access directly to S3 buckets
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Ensure the AWS account strictly owns all uploaded files
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- uploads bucket: CORS, lifecycle expiry, and SQS event notifications ---

# CORS policy: allows the user's browser to upload video directly via HTTP PUT
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

# Cost saver: auto-delete raw videos after 3 days once they are transcoded
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

# Event trigger: automatically notify SQS whenever a new .mp4 file lands in raw/
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

# --- processed + frontend buckets: private access restricted to CloudFront CDN ---

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

# Bucket policy: strictly allows only our CloudFront distribution to read media/frontend files
resource "aws_s3_bucket_policy" "cloudfront_read" {
  for_each = data.aws_iam_policy_document.cloudfront_read

  bucket = aws_s3_bucket.this[each.key].id
  policy = each.value.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
