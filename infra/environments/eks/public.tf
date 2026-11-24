# prod 공개 입구: 인증서(ACM)·DNS(Route 53)·WAF·AWS Load Balancer Controller IRSA. 설명·순서는 docs/eks-public.md.
# 모두 EKS 스택 안에 있어서 EKS를 지우면 같이 지워진다(WAF를 켜 둔 채 잊는 과금 방지).
# ALB 자체는 컨트롤러가 Ingress에서 만든다. 그래서 지울 때는 Ingress를 먼저 지워 ALB를 없앤 뒤 destroy한다.
# (ALB에 연결된 WAF는 지워지지 않아 destroy가 멈춘다: ALB를 남긴 채 지우는 실수를 막는 장치로 둔다.)
locals {
  public_count = var.public_enabled ? 1 : 0
  # 공개 주소는 하위 도메인 하나(기본 ureka.magonjal.com). apex·www는 지금 공개하지 않는다.
  public_hosts = var.public_enabled ? toset([var.public_host]) : toset([])
  # 컨트롤러 IngressClassParams의 group 이름과 같아야 한다(argocd/eks/aws-load-balancer-controller-app.yaml).
  public_alb_group    = "ureka-prod"
  lbc_service_account = "system:serviceaccount:kube-system:aws-load-balancer-controller"
  admin_path_prefixes = ["/admin", "/api/admin"]
  # Ingress 주석 alb.ingress.kubernetes.io/security-groups가 이 Name 태그로 찾는다(charts/ureka-public-ingress).
  alb_security_group = "${local.name}-alb-public"
  # 순서대로 적용: 디코딩 → 경로 정규화(//, /./, /../) → 소문자.
  path_transforms = ["URL_DECODE", "NORMALIZE_PATH", "LOWERCASE"]
  # 소문자로 바꾼 원래 경로에서 찾는다. 정상 화면·API 경로에는 나오지 않는 형식만 넣는다.
  # AWS WAF 정규식은 캡처 그룹(괄호)을 지원하지 않는다: 괄호 없이 대안(|)만 쓴다(tests/public.tftest.hcl이 괄호 없음을 검사).
  ambiguous_path_regex = "//|/\\.\\./|/\\./|/\\.\\.$|/\\.$|%2e|%2f|%5c|%25|%00|\\\\|;"
}

# 도메인 구매 때 Route 53이 만든 공개 호스팅 영역(apex). Terraform이 만들거나 지우지 않는다. 하위 도메인 레코드를 이 영역에 만든다.
data "aws_route53_zone" "public" {
  count        = local.public_count
  name         = var.public_domain
  private_zone = false
}

# ---------- 인증서 (DNS 검증, 무료) ----------
resource "aws_acm_certificate" "public" {
  count             = local.public_count
  domain_name       = var.public_host
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"
  options {
    certificate_transparency_logging_preference = "ENABLED"
  }
  lifecycle {
    create_before_destroy = true
  }
}

# 같은 계정·같은 도메인은 검증 CNAME이 같아서, 다시 켤 때도 몇 분 안에 검증된다(지난번 destroy가 레코드를 지웠으므로 충돌 없음).
resource "aws_route53_record" "cert_validation" {
  for_each = local.public_hosts
  zone_id  = data.aws_route53_zone.public[0].zone_id
  name     = one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type     = one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  records  = [one([for o in aws_acm_certificate.public[0].domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
  ttl      = 300
  # 같은 이름의 레코드가 이미 있으면 덮어쓰지 않고 멈춘다(다른 스택·사람의 레코드를 이 단기 스택이 가져가 destroy 때 지우지 않게).
  allow_overwrite = false
}

resource "aws_acm_certificate_validation" "public" {
  count                   = local.public_count
  certificate_arn         = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- ALB 입구 보안 그룹 (단계별 공개) ----------
# ALB 프런트엔드 SG를 Terraform이 소유한다. Ingress가 이름(Name 태그)으로 붙인다(charts/ureka-public-ingress).
# public_access_mode = "testers"(기본): 80/443을 시험자 /32 목록에서만 받는다. 목록이 비면 아무도 못 들어온다.
# public_access_mode = "open": 게이트(docs/eks-public.md) 통과·파트장 승인 뒤 별도 apply로 인터넷 전체 규칙을 더한다(시험자 규칙은 유지).
resource "aws_ec2_managed_prefix_list" "alb_testers" {
  count          = local.public_count
  name           = "${local.name}-alb-testers"
  address_family = "IPv4"
  max_entries    = 20
  dynamic "entry" {
    for_each = var.alb_tester_cidrs
    content {
      cidr = entry.value
    }
  }
}
resource "aws_security_group" "alb_public" {
  count       = local.public_count
  name        = local.alb_security_group
  description = "prod public ALB frontend; testers only until public_access_mode=open"
  vpc_id      = data.aws_vpc.shared.id
  tags        = { Name = local.alb_security_group }
}
resource "aws_vpc_security_group_ingress_rule" "alb_testers" {
  # open 단계에서도 지우지 않는다: open 전환 plan이 생성 2개만 되어 운영 도구 일반 plan(삭제 거부)으로 적용할 수 있다.
  for_each          = var.public_enabled ? toset(["80", "443"]) : toset([])
  security_group_id = aws_security_group.alb_public[0].id
  prefix_list_id    = aws_ec2_managed_prefix_list.alb_testers[0].id
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  description       = "Testers only (private tfvars)"
}
resource "aws_vpc_security_group_ingress_rule" "alb_open" {
  for_each          = var.public_enabled && var.public_access_mode == "open" ? toset(["80", "443"]) : toset([])
  security_group_id = aws_security_group.alb_public[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  description       = "Public after gate approval"
}
# ALB → Pod(대상 ip, 컨테이너 8080). 노드 SG 쪽 허용은 컨트롤러가 관리하는 백엔드 SG 규칙으로 추가된다
# (Ingress 주석 manage-backend-security-group-rules=true).
resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  count             = local.public_count
  security_group_id = aws_security_group.alb_public[0].id
  cidr_ipv4         = data.aws_vpc.shared.cidr_block
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  description       = "ALB to prod Pods (target type ip)"
}

# ---------- WAF ----------
# 관리자 경로를 열어 줄 IP. 값은 비공개 tfvars에만 있다(Ingress 주석에 쓰면 Git에 IP가 남는다).
resource "aws_wafv2_ip_set" "admin" {
  count              = local.public_count
  name               = "${local.name}-admin-allow"
  description        = "Admin path allow list - values in private tfvars"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.admin_path_allowed_cidrs
}

# 요청 샘플링은 끈다: 샘플에는 Cookie·Authorization 헤더가 들어갈 수 있다. 요청 원문 로그(WAF logging)도 켜지 않는다. 지표만 본다.
# 규칙 순서(priority)
#   5  모호한 경로(이중 슬래시·점 경로·인코딩된 / . \ %·세미콜론) 거부 → WAF가 보는 경로와 ALB·앱이 해석하는 경로가 달라지는 것을 막는다
#  10  공개 공지 GET(변환 없이 정확히 같은 경로만) 허용
#  20  관리자 경로를 허용 IP 밖에서 차단
#  30  비회원 토큰 발급 IP별 요청 수 제한
# 20·30은 URL 디코딩 → 경로 정규화 → 소문자로 바꾼 뒤 비교해 넓게 잡는다(앱이 실제로 받는 경로보다 좁아지지 않게).
resource "aws_wafv2_web_acl" "public" {
  count       = local.public_count
  name        = "${local.name}-public"
  description = "prod public ALB: ambiguous path reject, admin path IP allow list, guest token issuance rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "block-ambiguous-path"
    priority = 5
    action {
      block {
        custom_response {
          response_code = 400
        }
      }
    }
    statement {
      regex_match_statement {
        regex_string = local.ambiguous_path_regex
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-ambiguous-path"
      sampled_requests_enabled   = false
    }
  }

  # 공개 장애 공지 조회만 관리자 경로 예외(로그인 전 화면이 부른다). GET + 변환 없이 정확히 같은 경로일 때만.
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
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow-public-notice"
      sampled_requests_enabled   = false
    }
  }

  # 관리자 화면·API: 허용 IP가 아니면 403.
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
                  dynamic "text_transformation" {
                    for_each = local.path_transforms
                    content {
                      priority = text_transformation.key
                      type     = text_transformation.value
                    }
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
      sampled_requests_enabled   = false
    }
  }

  # 비회원 토큰 발급: IP별 요청 수 제한(#81, 위협 모델 T1의 주 방어 ②). 넘으면 429.
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
                dynamic "text_transformation" {
                  for_each = local.path_transforms
                  content {
                    priority = text_transformation.key
                    type     = text_transformation.value
                  }
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
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-public"
    sampled_requests_enabled   = false
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
# 목록 조회(aws_lbs)는 ALB가 없어도 실패하지 않는다. 그래서 끄는 순서(Ingress 삭제 → destroy)에서 플래그를 켠 채로 destroy plan을 만들 수 있다.
# 플래그가 켜져 있는데 ALB가 없으면 별칭 레코드는 삭제 계획이 된다(운영 도구의 일반 plan은 삭제가 있으면 멈춘다).
data "aws_lbs" "public" {
  count = var.public_dns_enabled ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = local.name
    "ingress.k8s.aws/stack" = local.public_alb_group
  }
}
locals {
  public_alb_arns = var.public_dns_enabled ? tolist(data.aws_lbs.public[0].arns) : []
}
data "aws_lb" "public" {
  count = length(local.public_alb_arns) == 1 ? 1 : 0
  arn   = local.public_alb_arns[0]
}
resource "aws_route53_record" "public" {
  for_each = length(data.aws_lb.public) == 1 ? local.public_hosts : toset([])
  zone_id  = data.aws_route53_zone.public[0].zone_id
  name     = each.key
  type     = "A"
  alias {
    name                   = data.aws_lb.public[0].dns_name
    zone_id                = data.aws_lb.public[0].zone_id
    evaluate_target_health = true
  }
}
check "public_alb_found" {
  assert {
    condition     = !var.public_dns_enabled || length(local.public_alb_arns) == 1
    error_message = "public_dns_enabled=true but the prod IngressGroup ALB was not found exactly once; DNS records will not be created (or will be removed)."
  }
}
