# 공유 실행 환경 EC2 + k3s (이슈 #32). network를 먼저 apply한 뒤 plan한다.
# network state를 읽지 않고 태그로 찾는다. VPC·서브넷이 0개나 여러 개면 data 조회가 실패해 plan이 멈춘다.
# 계정 ID는 코드에 쓰지 않고 실행 계정에서 읽는다(allowed_account_ids가 계정을 고정한다).

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_vpc" "shared" {
  tags = {
    Project = var.project_name
    Stack   = "network"
  }
}

data "aws_subnet" "public" {
  vpc_id            = data.aws_vpc.shared.id
  availability_zone = var.availability_zone

  tags = {
    Project = var.project_name
    Stack   = "network"
    Tier    = "public"
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  ecr_registry        = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  ecr_repository_arns = [for s in var.services : "arn:aws:ecr:${local.region}:${local.account_id}:repository/${var.project_name}/${s}"]
}

module "k3s_host" {
  source = "../../modules/k3s_host"

  name          = "${var.project_name}-dev"
  vpc_id        = data.aws_vpc.shared.id
  subnet_id     = data.aws_subnet.public.id
  instance_type = var.instance_type
  cpu_credits   = var.cpu_credits

  ecr_registry        = local.ecr_registry
  ecr_repository_arns = local.ecr_repository_arns
}
