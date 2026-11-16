# 공유 실행 환경 VPC. EC2(지금)·RDS(S7)·EKS(S8)가 같이 쓴다.
# - 공개 서브넷 2개: 지금은 EC2, S8에 ALB(서로 다른 AZ 서브넷 2개 필요)·NAT
# - 사설 서브넷 2개: RDS·EKS 노드. 인터넷으로 나가는 경로가 없다(NAT는 S8에 추가)
# 서브넷은 공개 IP를 자동으로 주지 않는다. 공개 IP가 필요한 자원이 직접 요청한다.

locals {
  azs = { for i, az in var.availability_zones : tostring(i) => az }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

# 기본 보안 그룹은 규칙을 모두 비워 둔다. 실수로 기본 그룹을 붙여도 아무 통신이 되지 않는다.
resource "aws_default_security_group" "this" {
  vpc_id  = aws_vpc.this.id
  ingress = []
  egress  = []

  tags = {
    Name = "${var.name}-default-deny"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.azs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = var.public_subnet_cidrs[tonumber(each.key)]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.name}-public-${each.value}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = local.azs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = var.private_subnet_cidrs[tonumber(each.key)]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.name}-private-${each.value}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-public"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# 사설 라우팅 표: VPC 안(local) 경로만. S8에 NAT를 넣을 때 여기에 기본 경로를 추가한다.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route  = []

  tags = {
    Name = "${var.name}-private"
    Tier = "private"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
