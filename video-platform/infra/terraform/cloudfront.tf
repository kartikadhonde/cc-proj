# One CloudFront distribution with three origins:
#   /*                          -> Frontend S3 bucket (cached)
#   /processed/*, /thumbnails/*  -> Transcoded media S3 bucket (cached)
#   /api/*                      -> Application Load Balancer (not cached)
# Routing everything through CloudFront provides single-origin HTTPS and prevents CORS issues.

locals {
  origin_frontend  = "frontend-s3"
  origin_processed = "processed-s3"
  origin_api       = "api-alb"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Origin Access Control (OAC): lets CloudFront securely fetch files from private S3 buckets
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# The main CloudFront CDN distribution: handles global caching, SSL/TLS, and path routing
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = local.name
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes India edge locations
  http_version        = "http2and3"

  # Origin 1: S3 bucket hosting our frontend single-page web app
  origin {
    origin_id                = local.origin_frontend
    domain_name              = aws_s3_bucket.this["frontend"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # Origin 2: S3 bucket holding transcoded videos (720p/480p) and thumbnails
  origin {
    origin_id                = local.origin_processed
    domain_name              = aws_s3_bucket.this["processed"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # Origin 3: Application Load Balancer (ALB) pointing to our FastAPI backend
  origin {
    origin_id   = local.origin_api
    domain_name = aws_lb.api.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default route (/*): serves the static website from S3 with edge caching
  default_cache_behavior {
    target_origin_id       = local.origin_frontend
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  # Media route (/processed/* and /thumbnails/*): fast global streaming of transcoded videos
  dynamic "ordered_cache_behavior" {
    for_each = ["/processed/*", "/thumbnails/*"]
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = local.origin_processed
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
      compress               = false # video/jpeg are already compressed
    }
  }

  # API route (/api/*): forwards dynamic requests straight to ALB without caching
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = local.origin_api
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # SPA fallback: redirects 403/404 back to index.html so single-page client routing works
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
