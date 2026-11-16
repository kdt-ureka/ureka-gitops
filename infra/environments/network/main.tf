# 공유 실행 환경 네트워크(이슈 #32). 프로젝트 끝까지 두는 층이라 EC2·RDS·EKS와 state를 나눈다.
# 다른 층은 이 state를 읽지 않고 태그(Project + Stack=network + Tier)로 VPC·서브넷을 찾는다.
#
# 주소 배치 (vpc_cidr = 10.0.0.0/16 기준)
#   공개 /24 × 2: 10.0.0.0/24, 10.0.1.0/24   (EC2, S8 ALB·NAT)
#   사설 /20 × 2: 10.0.16.0/20, 10.0.32.0/20 (RDS, S8 EKS 노드·Pod. Pod가 VPC IP를 써서 넉넉히)

module "network" {
  source = "../../modules/network"

  name               = var.project_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
}
