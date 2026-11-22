# prod 공개 입구(#64·#81) 정책 시험. mock provider만 쓴다: command=apply도 시험 메모리 안에서만 바뀌고 AWS는 건드리지 않는다.
mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }
  }
  mock_resource "aws_wafv2_ip_set" {
    defaults = { arn = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/ipset/ureka-eks-admin-allow/TEST" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/TEST"
      domain_validation_options = [
        { domain_name = "magonjal.com", resource_record_name = "_a.magonjal.com.", resource_record_type = "CNAME", resource_record_value = "_a.acm-validations.aws." },
        { domain_name = "www.magonjal.com", resource_record_name = "_b.www.magonjal.com.", resource_record_type = "CNAME", resource_record_value = "_b.acm-validations.aws." },
      ]
    }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0", cidr_block = "10.0.0.0/16" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_ec2_managed_prefix_list" {
    defaults = { id = "pl-0123456789abcdef0" }
  }
  mock_data "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
  mock_data "aws_route_table" {
    defaults = { id = "rtb-0123456789abcdef0" }
  }
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z0000000000TEST" }
  }
  mock_data "aws_lbs" {
    defaults = { arns = ["arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/k8s-urekaprod-test/TEST"] }
  }
  mock_data "aws_lb" {
    defaults = { dns_name = "k8s-urekaprod-test.ap-northeast-2.elb.amazonaws.com", zone_id = "ZALBTEST" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      identity = [{ oidc = [{ issuer = "https://oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }] }]
    }
  }
}
variables {
  allowed_account_ids       = ["123456789012"]
  admin_role_arn            = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Admin_test"
  admin_public_access_cidrs = ["192.0.2.1/32"]
  ami_release_version       = "1.37.0-20261120"
  addon_versions = {
    vpc-cni            = "v1.22.3-eksbuild.1"
    coredns            = "v1.13.0-eksbuild.1"
    kube-proxy         = "v1.37.0-eksbuild.1"
    aws-ebs-csi-driver = "v1.60.0-eksbuild.1"
  }
}

run "public_off_by_default" {
  command = plan
  assert {
    condition     = length(aws_wafv2_web_acl.public) == 0 && length(aws_acm_certificate.public) == 0 && length(aws_iam_role.lbc) == 0 && length(aws_route53_record.public) == 0
    error_message = "Without public_enabled no public entry resource may exist."
  }
}

run "public_phase_one" {
  command = apply
  variables {
    public_enabled           = true
    admin_path_allowed_cidrs = ["198.51.100.7/32"]
    alb_tester_cidrs         = ["203.0.113.5/32"]
  }
  assert {
    condition     = aws_acm_certificate.public[0].domain_name == "magonjal.com" && toset(aws_acm_certificate.public[0].subject_alternative_names) == toset(["www.magonjal.com"]) && aws_acm_certificate.public[0].validation_method == "DNS"
    error_message = "Certificate covers apex and www with DNS validation."
  }
  assert {
    condition     = toset(keys(aws_route53_record.cert_validation)) == toset(["magonjal.com", "www.magonjal.com"]) && aws_route53_record.cert_validation["www.magonjal.com"].name == "_b.www.magonjal.com."
    error_message = "One validation record per host, taken from that host's option."
  }
  assert {
    condition     = length(aws_route53_record.public) == 0 && length(data.aws_lb.public) == 0
    error_message = "Phase one must not need an existing ALB."
  }
  assert {
    condition     = aws_wafv2_web_acl.public[0].scope == "REGIONAL" && length(aws_wafv2_web_acl.public[0].default_action[0].allow) == 1
    error_message = "Regional ACL for ALB with default allow."
  }
  assert {
    condition     = toset(aws_wafv2_ip_set.admin[0].addresses) == toset(["198.51.100.7/32"]) && aws_wafv2_ip_set.admin[0].ip_address_version == "IPV4"
    error_message = "Admin allow list comes only from the private variable."
  }
  # 규칙 순서(priority): 모호한 경로 거부(5) → 공지 예외(10) → 관리자 차단(20) → 발급 제한(30). 정확히 4개.
  assert {
    condition     = toset([for r in aws_wafv2_web_acl.public[0].rule : "${r.priority}:${r.name}"]) == toset(["5:block-ambiguous-path", "10:allow-public-notice", "20:block-admin-outside-allowlist", "30:rate-limit-guest-tokens"])
    error_message = "Exactly the four reviewed WAF rules, in this priority order."
  }
  assert {
    condition     = !aws_wafv2_web_acl.public[0].visibility_config[0].sampled_requests_enabled && alltrue([for r in aws_wafv2_web_acl.public[0].rule : !r.visibility_config[0].sampled_requests_enabled && r.visibility_config[0].cloudwatch_metrics_enabled])
    error_message = "Request sampling (may hold Cookie/Authorization) is off; metrics stay on."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.public[0].rule : r.name != "block-ambiguous-path" || (
      r.action[0].block[0].custom_response[0].response_code == 400 &&
      r.statement[0].regex_match_statement[0].regex_string == local.ambiguous_path_regex &&
      length(r.statement[0].regex_match_statement[0].field_to_match[0].uri_path) == 1
    )])
    error_message = "Ambiguous path rule rejects with 400 on the URI path."
  }
  # 배포 문자열 자체: AWS WAF가 거부하는 괄호(캡처·비캡처 그룹)·되돌림 참조·전후방 탐색이 없다.
  assert {
    condition     = !strcontains(local.ambiguous_path_regex, "(") && !strcontains(local.ambiguous_path_regex, ")") && one([for r in aws_wafv2_web_acl.public[0].rule : r.statement[0].regex_match_statement[0].regex_string if r.name == "block-ambiguous-path"]) == "//|/\\.\\./|/\\./|/\\.\\.$|/\\.$|%2e|%2f|%5c|%25|%00|\\\\|;"
    error_message = "WAF regex must not contain parentheses; the deployed string is the reviewed one."
  }
  # RE2(Terraform)로 같은 정규식 동작 확인. WAF 실제 동작은 제한 단계 시험에서 다시 본다.
  assert {
    condition     = alltrue([for p in ["/api//admin/v1/x", "//api/admin", "/api/./admin", "/api/x/../admin", "/api/%2e%2e/admin", "/api/%2fadmin", "/api/%252e", "/api\\admin", "/api/admin;x/v1", "/api/%00", "/api/admin/..", "/api/admin/.", "/a/./b", "/a/../b"] : can(regex(local.ambiguous_path_regex, lower(p)))])
    error_message = "Ambiguous forms must match."
  }
  assert {
    condition     = alltrue([for p in ["/", "/admin", "/api/admin/v1/public-notice", "/api/auth/v1/guest-tokens", "/assets/index-abc.js", "/.well-known/x", "/movies/123", "/api/content/v1/people/%ec%9d%b4"] : !can(regex(local.ambiguous_path_regex, lower(p)))])
    error_message = "Normal paths must not match."
  }
  assert {
    condition     = alltrue([for r in aws_route53_record.cert_validation : !r.allow_overwrite])
    error_message = "Never take over an existing validation record."
  }
  assert {
    condition     = aws_security_group.alb_public[0].name == "ureka-eks-alb-public" && aws_security_group.alb_public[0].tags["Name"] == "ureka-eks-alb-public" && toset(keys(aws_vpc_security_group_ingress_rule.alb_testers)) == toset(["80", "443"]) && length(aws_vpc_security_group_ingress_rule.alb_open) == 0 && alltrue([for r in aws_vpc_security_group_ingress_rule.alb_testers : r.prefix_list_id == aws_ec2_managed_prefix_list.alb_testers[0].id && r.cidr_ipv4 == null])
    error_message = "Default testers mode: 80/443 only from the private tester list."
  }
  assert {
    condition     = length(aws_ec2_managed_prefix_list.alb_testers[0].entry) == 1 && one(aws_ec2_managed_prefix_list.alb_testers[0].entry).cidr == "203.0.113.5/32"
    error_message = "Tester list comes only from the private variable."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.alb_to_pods[0].from_port == 8080 && aws_vpc_security_group_egress_rule.alb_to_pods[0].to_port == 8080 && aws_vpc_security_group_egress_rule.alb_to_pods[0].cidr_ipv4 == "10.0.0.0/16"
    error_message = "ALB egress only to Pods in the VPC on 8080."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.public[0].rule : (
      r.name == "block-ambiguous-path" ? true :
      r.name == "allow-public-notice" ? r.priority == 10 && length(r.action[0].allow) == 1 && toset([for s in r.statement[0].and_statement[0].statement : s.byte_match_statement[0].search_string]) == toset(["GET", "/api/admin/v1/public-notice"]) && alltrue([for s in r.statement[0].and_statement[0].statement : s.byte_match_statement[0].positional_constraint == "EXACTLY" && [for t in s.byte_match_statement[0].text_transformation : t.type] == ["NONE"]]) :
      r.name == "block-admin-outside-allowlist" ? r.priority == 20 && length(r.action[0].block) == 1 && toset([for s in r.statement[0].and_statement[0].statement[0].or_statement[0].statement : s.byte_match_statement[0].search_string]) == toset(["/admin", "/api/admin"]) && alltrue([for s in r.statement[0].and_statement[0].statement[0].or_statement[0].statement : [for t in s.byte_match_statement[0].text_transformation : "${t.priority}:${t.type}"] == ["0:URL_DECODE", "1:NORMALIZE_PATH", "2:LOWERCASE"]]) && r.statement[0].and_statement[0].statement[1].not_statement[0].statement[0].ip_set_reference_statement[0].arn == aws_wafv2_ip_set.admin[0].arn :
      r.name == "rate-limit-guest-tokens" ? r.priority == 30 && r.action[0].block[0].custom_response[0].response_code == 429 : false
    )])
    error_message = "Notice exception is GET+exact raw path only; admin block decodes and normalizes, applies outside the IP set; rate rule answers 429."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.public[0].rule : r.name != "rate-limit-guest-tokens" || (
      r.statement[0].rate_based_statement[0].limit == 20 &&
      r.statement[0].rate_based_statement[0].evaluation_window_sec == 300 &&
      r.statement[0].rate_based_statement[0].aggregate_key_type == "IP" &&
      toset([for s in r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement : s.byte_match_statement[0].search_string]) == toset(["POST", "/api/auth/v1/guest-tokens"]) &&
      alltrue([for s in r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement : s.byte_match_statement[0].search_string == "POST" || [for t in s.byte_match_statement[0].text_transformation : t.type] == ["URL_DECODE", "NORMALIZE_PATH", "LOWERCASE"]])
    )])
    error_message = "Guest token issuance: POST, per IP, 20 per 5 minutes by default."
  }
  assert {
    condition     = jsondecode(aws_iam_role.lbc[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:kube-system:aws-load-balancer-controller" && jsondecode(aws_iam_role.lbc[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:aud"] == "sts.amazonaws.com"
    error_message = "Controller role trusts only its own ServiceAccount."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.lbc_waf_lookup[0].policy).Statement[0].Action == "wafv2:ListWebACLs" && length(jsondecode(aws_iam_role_policy.lbc_waf_lookup[0].policy).Statement) == 1 && aws_wafv2_web_acl.public[0].name == "ureka-eks-public"
    error_message = "Only the ACL list lookup is added; the ACL name must match IngressClassParams.wafv2AclName."
  }
  assert {
    condition     = sha256(file("${path.module}/policies/aws-load-balancer-controller-v3.6.3.json")) == "16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a"
    error_message = "Controller policy must be the unmodified official v3.6.3 file; review and update the hash with the chart."
  }
  assert {
    condition     = !strcontains(file("${path.module}/policies/aws-load-balancer-controller-v3.6.3.json"), "iam:PassRole") && !strcontains(file("${path.module}/policies/aws-load-balancer-controller-v3.6.3.json"), "\"*:*\"")
    error_message = "Controller policy must not grant PassRole or wildcard actions."
  }
}

run "public_phase_two_dns" {
  command = apply
  variables {
    public_enabled     = true
    public_dns_enabled = true
  }
  assert {
    condition     = toset(keys(aws_route53_record.public)) == toset(["magonjal.com", "www.magonjal.com"]) && alltrue([for r in aws_route53_record.public : r.type == "A" && r.alias[0].name == data.aws_lb.public[0].dns_name])
    error_message = "Apex and www alias to the controller ALB."
  }
  assert {
    condition     = data.aws_lbs.public[0].tags["ingress.k8s.aws/stack"] == "ureka-prod" && data.aws_lbs.public[0].tags["elbv2.k8s.aws/cluster"] == "ureka-eks"
    error_message = "ALB lookup is limited to this cluster's prod IngressGroup."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_open) == 0 && length(aws_ec2_managed_prefix_list.alb_testers[0].entry) == 0
    error_message = "DNS alone never opens the ALB; empty tester list lets nobody in."
  }
  assert {
    condition     = length(aws_wafv2_ip_set.admin[0].addresses) == 0
    error_message = "Default admin allow list is empty (fail closed)."
  }
}

# 끄는 순서: 2단계가 켜진 채 Ingress를 지워 ALB가 사라져도 plan이 실패하지 않고 별칭만 삭제 계획이 된다(destroy plan의 refresh도 같은 조회).
run "public_dns_alb_gone" {
  command = plan
  variables {
    public_enabled     = true
    public_dns_enabled = true
  }
  override_data {
    target = data.aws_lbs.public[0]
    values = { arns = [] }
  }
  assert {
    condition     = length(aws_route53_record.public) == 0 && length(data.aws_lb.public) == 0
    error_message = "Missing ALB must not fail planning; alias records drop out."
  }
  expect_failures = [check.public_alb_found]
}

run "public_open_after_gate" {
  command = apply
  variables {
    public_enabled     = true
    public_dns_enabled = true
    public_access_mode = "open"
  }
  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.alb_open)) == toset(["80", "443"]) && alltrue([for r in aws_vpc_security_group_ingress_rule.alb_open : r.cidr_ipv4 == "0.0.0.0/0"]) && toset(keys(aws_vpc_security_group_ingress_rule.alb_testers)) == toset(["80", "443"])
    error_message = "Open mode adds world 80/443 and keeps the tester rules (open plan is additions only)."
  }
}

run "rejects_unknown_access_mode" {
  command = plan
  variables {
    public_enabled     = true
    public_access_mode = "public"
  }
  expect_failures = [var.public_access_mode]
}

run "dns_requires_public" {
  command = plan
  variables {
    public_dns_enabled = true
  }
  expect_failures = [var.public_dns_enabled]
}

run "rate_limit_floor" {
  command = plan
  variables {
    public_enabled         = true
    guest_token_rate_limit = 5
  }
  expect_failures = [var.guest_token_rate_limit]
}

run "admin_allowlist_only_single_hosts" {
  command = plan
  variables {
    public_enabled           = true
    admin_path_allowed_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_path_allowed_cidrs]
}
