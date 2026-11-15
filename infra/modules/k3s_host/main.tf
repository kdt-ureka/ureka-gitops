# 공유 실행 환경 EC2 한 대 + k3s (이슈 #32).
# - 인바운드 0개, 아웃바운드 TCP 443만. 사람은 SSM으로만 들어온다(SSH 키·22번 없음).
# - 공개 IP는 나가는 용도(GitHub·ECR·SSM·Gemini). S8에 NAT를 넣으면 사설 서브넷으로 옮긴다.
# - IMDSv2 필수 + hop limit 1: 노드(kubelet의 ecr-credential-provider)만 Role 자격을 받고 Pod는 못 받는다.
# - 이 서버는 다시 만들지 않는다(k3s 상태·Secret이 루트 디스크에만 있음). AMI·user data가 바뀌어도
#   교체되지 않게 무시하고, 교체가 필요하면 승인 후 `terraform apply -replace`로 한다.

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_region" "current" {}

# --- 보안 그룹 -----------------------------------------------------------------

resource "aws_security_group" "host" {
  name        = "${var.name}-k3s-host"
  description = "k3s host: no inbound, outbound HTTPS only"
  vpc_id      = var.vpc_id

  ingress = []

  egress {
    description = "HTTPS to GitHub, ECR, S3 layers, SSM, Gemini, AL2023 repos, k3s artifacts"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]

    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
    self             = false
  }

  tags = {
    Name = "${var.name}-k3s-host"
  }
}

# --- IAM -----------------------------------------------------------------------

resource "aws_iam_role" "host" {
  name = "${var.name}-k3s-host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM 에이전트용 관리형 정책. 범위가 넓은 것을 알고 첫 버전에서 수용한다(이슈 #32 한계).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 우리 서비스 저장소에서 이미지 받기만. push·삭제·정책 변경 없음.
resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull-service-repositories"
  role = aws_iam_role.host.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPullServiceRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = var.ecr_repository_arns
      },
    ]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-k3s-host"
  role = aws_iam_role.host.name
}

# --- SSM 포트 포워딩 문서: 목적지 80번 고정 -----------------------------------------
# 기본 AWS-StartPortForwardingSession은 목적지 포트를 사용자가 바꿀 수 있다.
# 팀원 권한 세트(팀원 공개 PR)는 이 문서만 허용한다. 로컬 포트만 고를 수 있다.

resource "aws_ssm_document" "port_forward_http" {
  name            = "${var.name}-PortForwardHttp80"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Port forwarding to the k3s host port 80 (Traefik) only."
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        description    = "Local port on your machine (1024-65535)."
        allowedPattern = "^(102[4-9]|10[3-9][0-9]|1[1-9][0-9]{2}|[2-9][0-9]{3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        default        = "8080"
      }
    }
    properties = {
      type            = "LocalPortForwarding"
      portNumber      = "80"
      localPortNumber = "{{ localPortNumber }}"
    }
  })
}

# --- EC2 -----------------------------------------------------------------------

locals {
  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    k3s_version                     = var.k3s_version
    k3s_sha256                      = var.k3s_sha256
    k3s_install_sha256              = var.k3s_install_sha256
    ecr_credential_provider_version = var.ecr_credential_provider_version
    ecr_credential_provider_sha256  = var.ecr_credential_provider_sha256
    ecr_registry                    = var.ecr_registry
    aws_region                      = data.aws_region.current.region
  })
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true
  disable_api_termination     = var.termination_protection
  monitoring                  = false

  user_data                   = local.user_data
  user_data_replace_on_change = false

  credit_specification {
    cpu_credits = var.cpu_credits
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_protocol_ipv6          = "disabled"
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name}-k3s-root"
    }
  }

  tags = {
    Name = "${var.name}-k3s"
    Role = "k3s-host"
  }

  lifecycle {
    # 새 AMI·user data로 서버가 저절로 교체되지 않게 한다. 교체는 승인 후 -replace로만.
    ignore_changes = [ami, user_data]
  }
}
