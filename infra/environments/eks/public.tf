# prod 공개 입구: 인증서(ACM)·DNS(Route 53)·WAF·AWS Load Balancer Controller IRSA. 설명·순서는 docs/eks-public.md.
# 모두 EKS 스택 안에 있어서 EKS를 지우면 같이 지워진다(WAF를 켜 둔 채 잊는 과금 방지).
# ALB 자체는 컨트롤러가 Ingress에서 만든다. 그래서 지울 때는 Ingress를 먼저 지워 ALB를 없앤 뒤 destroy한다.
# (ALB에 연결된 WAF는 지워지지 않아 destroy가 멈춘다: ALB를 남긴 채 지우는 실수를 막는 장치로 둔다.)
locals {
  public_count = var.public_enabled ? 1 : 0
  public_hosts = var.public_enabled ? toset([var.public_domain, "www.${var.public_domain}"]) : toset([])
  # 컨트롤러 IngressClassParams의 group 이름과 같아야 한다(argocd/eks/aws-load-balancer-controller-app.yaml).
  public_alb_group    = "ureka-prod"
  lbc_service_account = "system:serviceaccount:kube-system:aws-load-balancer-controller"
  admin_path_prefixes = ["/admin", "/api/admin"]
}

# 도메인 구매 때 Route 53이 만든 공개 호스팅 영역. Terraform이 만들거나 지우지 않는다.
data "aws_route53_zone" "public" {
  count        = local.public_count
  name         = var.public_domain
  private_zone = false
}

# ---------- 인증서 (DNS 검증, 무료) ----------
resource "aws_acm_certificate" "public" {
  count                     = local.public_count
  domain_name               = var.public_domain
  subject_alternative_names = ["www.${var.public_domain}"]
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"
  options {
    certificate_transparency_logging_preference = "ENABLED"
  }
  lifecycle {
    create_before_destroy = true
  }
}

# 같은 계정·같은 도메인은 검증 CNAME이 같아서, 다시 켤 때도 몇 분 안에 검증된다.
resource "aws_route53_record" "cert_validation" {
  for_each        = local.public_hosts
  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type            = one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  records         = [one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "public" {
  count                   = local.public_count
  certificate_arn         = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- WAF ----------
# 관리자 경로를 열어 줄 IP. 값은 비공개 tfvars에만 있다(Ingress 주석에 쓰면 Git에 IP가 남는다).
resource "aws_wafv2_ip_set" "admin" {
  count              = local.public_count
  name               = "${local.name}-admin-allow"
  description        = "Admin path allow list (values in private tfvars)"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.admin_path_allowed_cidrs
}

resource "aws_wafv2_web_acl" "public" {
  count       = local.public_count
  name        = "${local.name}-public"
  description = "prod public ALB: admin path IP allow list, guest token issuance rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # 1) 공개 장애 공지 조회만 관리자 경로 예외(로그인 전 화면이 부른다). GET + 정확한 경로일 때만.
  rule {
    name     = "allow-public-notice"
    priority = 10
    action {
      allow {}
    }
    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "GET"
            positional_constraint = "EXACTLY"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "/api/admin/v1/public-notice"
            positional_constraint = "EXACTLY"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "URL_DECODE"
            }
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow-public-notice"
      sampled_requests_enabled   = true
    }
  }

  # 2) 관리자 화면·API: 허용 IP가 아니면 403. 인코딩·대소문자를 바꿔 피하지 못하게 디코딩·소문자 변환 뒤 비교한다.
  rule {
    name     = "block-admin-outside-allowlist"
    priority = 20
    action {
      block {}
    }
    statement {
      and_statement {
        statement {
          or_statement {
            dynamic "statement" {
              for_each = local.admin_path_prefixes
              content {
                byte_match_statement {
                  search_string         = statement.value
                  positional_constraint = "STARTS_WITH"
                  field_to_match {
                    uri_path {}
                  }
                  text_transformation {
                    priority = 0
                    type     = "URL_DECODE"
                  }
                  text_transformation {
                    priority = 1
                    type     = "LOWERCASE"
                  }
                }
              }
            }
          }
        }
        statement {
          not_statement {
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.admin[0].arn
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-admin-outside-allowlist"
      sampled_requests_enabled   = true
    }
  }

  # 3) 비회원 토큰 발급: IP별 요청 수 제한(#81, 위협 모델 T1의 주 방어 ②). 넘으면 429.
  # 추정 기반이라 정확한 숫자에서 바로 막히지는 않는다(AWS가 몇십 초 늦게 반영할 수 있음).
  rule {
    name     = "rate-limit-guest-tokens"
    priority = 30
    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.guest_token_rate_limit
        evaluation_window_sec = var.guest_token_rate_window_sec
        aggregate_key_type    = "IP"
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"
                field_to_match {
                  method {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/api/auth/v1/guest-tokens"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "URL_DECODE"
                }
                text_transformation {
                  priority = 1
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-guest-tokens"
      sampled_requests_enabled   = true
    }
  }

  # 요청 원문 로그(WAF logging)는 비용·개인정보 때문에 켜지 않는다. 지표와 샘플 요청만 본다.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-public"
    sampled_requests_enabled   = true
  }
}

# ---------- AWS Load Balancer Controller IRSA ----------
# kube-system의 컨트롤러 ServiceAccount 하나만 이 역할을 쓴다. 정책은 v3.6.3 공식 iam_policy.json 그대로(차트 버전과 같이 올린다).
resource "aws_iam_role" "lbc" {
  count = local.public_count
  name  = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${local.oidc_host}:sub" = local.lbc_service_account
        "${local.oidc_host}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}
resource "aws_iam_policy" "lbc" {
  count       = local.public_count
  name        = "${local.name}-aws-load-balancer-controller"
  description = "Official AWS Load Balancer Controller v3.6.3 policy"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.6.3.json")
}
resource "aws_iam_role_policy_attachment" "lbc" {
  count      = local.public_count
  role       = aws_iam_role.lbc[0].name
  policy_arn = aws_iam_policy.lbc[0].arn
}
# IngressClassParams.wafv2AclName(이름으로 WAF 지정)을 쓰려면 목록 조회가 더 필요하다(공식 정책 파일에는 없음, 공식 주석 문서에 명시).
# 이름으로 지정하면 ARN(계정 ID 포함)을 Git에 쓰지 않아도 된다. 목록 조회는 리소스 단위 제한이 없는 동작이다.
resource "aws_iam_role_policy" "lbc_waf_lookup" {
  count = local.public_count
  name  = "wafv2-list-web-acls"
  role  = aws_iam_role.lbc[0].name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "wafv2:ListWebACLs", Resource = "*" }]
  })
}

# ---------- DNS (2단계) ----------
# 컨트롤러가 만든 ALB를 태그로 찾는다. 다른 스택의 state를 읽지 않는다.
data "aws_lb" "public" {
  count = var.public_dns_enabled ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = local.name
    "ingress.k8s.aws/stack" = local.public_alb_group
  }
}
resource "aws_route53_record" "public" {
  for_each = var.public_dns_enabled ? local.public_hosts : toset([])
  zone_id  = data.aws_route53_zone.public[0].zone_id
  name     = each.key
  type     = "A"
  alias {
    name                   = data.aws_lb.public[0].dns_name
    zone_id                = data.aws_lb.public[0].zone_id
    evaluate_target_health = true
  }
}
