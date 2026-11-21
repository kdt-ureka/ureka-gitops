# dev RDS PostgreSQL (이슈 #32 RDS 단계). network·ec2를 먼저 apply한 뒤 plan한다.
# 다른 스택 state를 읽지 않고 태그·이름으로 찾는다. 0개나 여러 개면 data 조회가 실패해 plan이 멈춘다.
# EC2 서비스가 먼저 쓰고, EKS(S8)가 같은 인스턴스를 재사용한다(그때 EKS 노드 보안 그룹을 허용 목록에 더한다).
#
# 접근 경계
# - 인터넷 공개 안 함(publicly_accessible = false), 사설 서브넷 2개(DB 서브넷 그룹 요구 조건)에만 둔다.
# - 인바운드는 EC2 호스트 + 명시한 EKS 노드 SG의 TCP 5432만. 아웃바운드는 없다.
# - 마스터 비밀번호는 RDS가 Secrets Manager에 만들고 관리한다(Terraform state·Git·사람 손에 원문이 없다).
#   EC2 호스트 역할은 그 비밀 1개에 GetSecretValue만 받는다(List·다른 비밀 없음).
#   서버 안 스크립트가 db-bootstrap Job을 돌리는 동안만 클러스터 Secret으로 두고 끝나면 지운다(scripts/ec2/rds-bootstrap.sh).

data "aws_vpc" "shared" {
  tags = {
    Project = var.project_name
    Stack   = "network"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  tags = {
    Project = var.project_name
    Stack   = "network"
    Tier    = "private"
  }
}

# EC2 호스트(environments/ec2, modules/k3s_host)가 만든 보안 그룹·역할. 이름은 "<project>-dev-k3s-host".
data "aws_security_group" "ec2_host" {
  vpc_id = data.aws_vpc.shared.id
  name   = "${local.ec2_name}-k3s-host"

  tags = {
    Project = var.project_name
    Stack   = "ec2"
  }
}

data "aws_iam_role" "ec2_host" {
  name = "${local.ec2_name}-k3s-host"
}

locals {
  name     = "${var.project_name}-dev"
  ec2_name = "${var.project_name}-dev"
}

resource "aws_db_subnet_group" "this" {
  name        = "${local.name}-private"
  description = "Private subnets only (no internet route)"
  subnet_ids  = data.aws_subnets.private.ids

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.private.ids) == 2
      error_message = "Expected exactly two private subnets tagged by the network stack."
    }
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL: 5432 from the k3s host only, no egress"
  vpc_id      = data.aws_vpc.shared.id

  ingress {
    description     = "PostgreSQL from the k3s host"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [data.aws_security_group.ec2_host.id]

    cidr_blocks      = []
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    self             = false
  }

  dynamic "ingress" {
    for_each = var.eks_node_security_group_ids
    content {
      description      = "PostgreSQL from EKS nodes and VPC CNI Pods"
      protocol         = "tcp"
      from_port        = 5432
      to_port          = 5432
      security_groups  = [ingress.value]
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      self             = false
    }
  }

  egress = []

  tags = {
    Name = "${local.name}-rds"
  }
}

resource "aws_db_parameter_group" "this" {
  name        = "${local.name}-pg${var.engine_version}"
  family      = "postgres${var.engine_version}"
  description = "Ureka dev: TLS required"

  # PostgreSQL 15 이후 기본값도 1이지만, 접속 조건을 코드에 남긴다.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage_gib
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = var.availability_zone
  publicly_accessible    = false
  multi_az               = false
  port                   = 5432
  parameter_group_name   = aws_db_parameter_group.this.name

  # 서비스 DB·계정·vector 확장은 db-bootstrap이 이 계정(rds_superuser)으로 만든다. 앱은 이 계정을 쓰지 않는다.
  username                    = "ureka_admin"
  manage_master_user_password = true

  backup_retention_period   = var.backup_retention_days
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final"
  copy_tags_to_snapshot     = true

  auto_minor_version_upgrade   = true
  performance_insights_enabled = false
  monitoring_interval          = 0
  apply_immediately            = false

  tags = {
    Name = local.name
  }
}

# EC2 호스트가 마스터 비밀 1개만 읽는다(db-bootstrap 실행 때). 다른 비밀·목록 조회는 없다.
# 기본 KMS 키(aws/secretsmanager)라 kms 권한은 따로 주지 않는다.
resource "aws_iam_role_policy" "ec2_read_master_secret" {
  name = "rds-master-secret-read"
  role = data.aws_iam_role.ec2_host.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadRdsMasterSecretOnly"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_db_instance.this.master_user_secret[0].secret_arn]
    }]
  })
}
