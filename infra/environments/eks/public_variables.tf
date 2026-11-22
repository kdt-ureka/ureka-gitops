# prod 공개 입구(#64 ALB·도메인·인증서, #81 WAF) 변수. 기본은 끔: dev만 시험할 때는 공개 자원을 만들지 않는다.
variable "public_enabled" {
  type        = bool
  default     = false
  description = "true면 ACM 인증서·WAF·AWS Load Balancer Controller IRSA를 만든다(EKS와 같이 생기고 같이 지워진다)."
}
variable "public_dns_enabled" {
  type        = bool
  default     = false
  description = "2단계: Ingress가 ALB를 만든 뒤 true로 바꿔 Route 53 별칭 레코드를 만든다. ALB가 없으면 plan이 실패한다."
  validation {
    condition     = !var.public_dns_enabled || var.public_enabled
    error_message = "public_dns_enabled needs public_enabled = true."
  }
}
variable "public_domain" {
  type        = string
  default     = "magonjal.com"
  description = "Route 53에 이미 있는 공개 호스팅 영역 이름(apex). 영역만 찾는 데 쓰고 apex 자체는 공개하지 않는다."
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.public_domain))
    error_message = "Use a lowercase apex domain such as example.com."
  }
}
variable "public_host" {
  type        = string
  default     = "ureka.magonjal.com"
  description = "prod 공개 주소. public_domain 영역 안의 하위 도메인 하나. 인증서·별칭·Ingress 호스트(environments/eks/prod/public-ingress.yaml)와 같아야 한다."
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.public_host)) && endswith(var.public_host, ".${var.public_domain}")
    error_message = "public_host must be a lowercase subdomain inside public_domain (apex is not published)."
  }
}
variable "admin_path_allowed_cidrs" {
  type        = list(string)
  default     = []
  sensitive   = true
  description = "관리자 경로(/admin, /api/admin)를 열어 줄 공인 IPv4 /32. 비우면 아무도 못 들어간다(공지 조회만 예외). Git에 쓰지 않는다."
  validation {
    condition     = alltrue([for c in var.admin_path_allowed_cidrs : can(cidrnetmask(c)) && endswith(c, "/32")])
    error_message = "Only IPv4 /32 entries; no ranges or world-open fallback."
  }
}
variable "guest_token_rate_limit" {
  type        = number
  default     = 20
  description = "IP 하나가 평가 창 동안 비회원 토큰 발급(POST)을 보낼 수 있는 최대 횟수. WAF 최소값 10."
  validation {
    condition     = var.guest_token_rate_limit >= 10 && var.guest_token_rate_limit <= 1000 && floor(var.guest_token_rate_limit) == var.guest_token_rate_limit
    error_message = "Use a whole number between 10 (WAF minimum) and 1000."
  }
}
variable "guest_token_rate_window_sec" {
  type        = number
  default     = 300
  description = "요청 수를 세는 평가 창(초). WAF가 허용하는 값만 쓴다."
  validation {
    condition     = contains([60, 120, 300, 600], var.guest_token_rate_window_sec)
    error_message = "WAF evaluation window must be 60, 120, 300 or 600 seconds."
  }
}
variable "public_access_mode" {
  type        = string
  default     = "testers"
  description = "ALB 입구. testers: alb_tester_cidrs에서만 80/443. open: 공개 전 게이트 통과·파트장 승인 뒤 인터넷 전체."
  validation {
    condition     = contains(["testers", "open"], var.public_access_mode)
    error_message = "public_access_mode must be testers or open."
  }
}
variable "alb_tester_cidrs" {
  type        = list(string)
  default     = []
  sensitive   = true
  description = "testers 단계에서 ALB에 들어올 수 있는 공인 IPv4 /32(관리자 + 관리자 목록에 없는 시험 IP 하나 이상). Git에 쓰지 않는다."
  validation {
    condition     = length(var.alb_tester_cidrs) <= 20 && alltrue([for c in var.alb_tester_cidrs : can(cidrnetmask(c)) && endswith(c, "/32")])
    error_message = "Up to 20 IPv4 /32 entries."
  }
}
