data "aws_route53_zone" "main" {
  name         = "sajid-platform.online"
  private_zone = false
}

resource "aws_acm_certificate" "dev" {
  domain_name       = "dev.sajid-platform.online"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.dev.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "dev" {
  certificate_arn         = aws_acm_certificate.dev.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

output "acm_certificate_arn" {
  value = aws_acm_certificate.dev.arn
}

data "aws_lb" "shared" {
  name = "k8s-ticketopsdev-b94f12db37"
}

resource "aws_route53_record" "dev_alias" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev.sajid-platform.online"
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}