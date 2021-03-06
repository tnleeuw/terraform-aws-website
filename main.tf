provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

locals {
  www_domain = "www.${var.domain}"

  domains = [
    "${var.domain}",
    "${local.www_domain}",
  ]

  bucket_domain_names = [
    "${aws_s3_bucket.redirect.bucket_domain_name}",
    "${aws_s3_bucket.main.bucket_domain_name}",
  ]
}

data "aws_route53_zone" "zone" {
  name = "${var.domain}"
}

data "template_file" "bucket_policy" {
  template = "${file("${path.module}/website_bucket_policy.json")}"

  vars {
    bucket = "${local.www_domain}"
    iam_arn= "${aws_cloudfront_origin_access_identity.orig_access_ident.iam_arn}"
  }
}

data "template_file" "redirect_bucket_policy" {
  template = "${file("${path.module}/website_bucket_policy.json")}"

  vars {
    bucket = "${var.domain}"
    iam_arn= "${aws_cloudfront_origin_access_identity.orig_access_ident.iam_arn}"
  }
}

resource "aws_s3_bucket" "main" {
  bucket = "${local.www_domain}"
  policy   = "${data.template_file.bucket_policy.rendered}"

  website = {
    index_document = "index.html"
    error_document = "index.html"
  }
}

resource "aws_s3_bucket" "redirect" {
  bucket = "${var.domain}"
  policy   = "${data.template_file.redirect_bucket_policy.rendered}"

  website = {
    redirect_all_requests_to = "${aws_s3_bucket.main.id}"
  }
}

resource "aws_route53_record" "A" {
  count   = "${length(local.domains)}"
  zone_id = "${data.aws_route53_zone.zone.zone_id}"
  name    = "${element(local.domains, count.index)}"
  type    = "A"

  alias {
    name                   = "${element(aws_cloudfront_distribution.cdn.*.domain_name, count.index)}"
    zone_id                = "${element(aws_cloudfront_distribution.cdn.*.hosted_zone_id, count.index)}"
    evaluate_target_health = false
  }
}

data "aws_acm_certificate" "ssl" {
  count    = "${length(local.domains)}"
  provider = "aws.us-east-1"            // this is an AWS requirement
  domain   = "${local.www_domain}"
  statuses = ["ISSUED"]
}

resource "aws_cloudfront_origin_access_identity" "orig_access_ident" {
  comment = "CloudFront Origin Access Identity to access S3 Bucket ${local.www_domain}"
}

resource "aws_cloudfront_distribution" "cdn" {
  count               = "${length(local.domains)}"
  enabled             = true
  default_root_object = "${element(local.domains, count.index) == local.www_domain ? "index.html" : ""}"
  aliases             = ["${element(local.domains, count.index)}"]
  is_ipv6_enabled     = true

  origin {
    domain_name = "${element(local.bucket_domain_names, count.index)}"
    origin_id   = "S3-${element(local.domains, count.index)}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.orig_access_ident.cloudfront_access_identity_path}"
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = "${element(data.aws_acm_certificate.ssl.*.arn, count.index)}"
    minimum_protocol_version = "TLSv1"
    ssl_support_method       = "sni-only"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${element(local.domains, count.index)}"
    compress         = "${var.enable_gzip}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  custom_error_response {
    error_code = 403
    response_code = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 300
  }

  custom_error_response {
    error_code = 404
    response_code = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 300
  }
}

resource "aws_route53_health_check" "health_check" {
  depends_on        = ["aws_route53_record.A"]
  count             = "${var.enable_health_check ? 1 : 0}"
  fqdn              = "${local.www_domain}"
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = "3"
  request_interval  = "30"

  tags = {
    Name = "${local.www_domain}"
  }
}

resource "aws_cloudwatch_metric_alarm" "health_check_alarm" {
  provider            = "aws.us-east-1"
  count               = "${var.enable_health_check ? 1 : 0}"
  alarm_name          = "${local.www_domain}-health-check"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1.0"
  alarm_description   = "This metric monitors the health of the endpoint"
  ok_actions          = "${var.health_check_alarm_sns_topics}"
  alarm_actions       = "${var.health_check_alarm_sns_topics}"
  treat_missing_data  = "breaching"

  dimensions {
    HealthCheckId = "${aws_route53_health_check.health_check.id}"
  }
}
