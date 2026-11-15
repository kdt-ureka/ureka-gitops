# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
mock_provider "aws" {}

variables {
  name                 = "ureka"
  vpc_cidr             = "10.0.0.0/16"
  availability_zones   = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.16.0/20", "10.0.32.0/20"]
}

run "vpc_and_subnets" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "VPC DNS support and hostnames must be on (EKS, SSM, RDS endpoints)."
  }

  assert {
    condition     = length(distinct([for s in aws_subnet.public : s.availability_zone])) == 2
    error_message = "Public subnets must be in two different AZs (ALB needs two)."
  }

  assert {
    condition     = length(distinct([for s in aws_subnet.private : s.availability_zone])) == 2
    error_message = "Private subnets must be in two different AZs (RDS subnet group, EKS)."
  }

  assert {
    condition     = alltrue([for s in concat(values(aws_subnet.public), values(aws_subnet.private)) : s.map_public_ip_on_launch == false])
    error_message = "No subnet may auto-assign public IPs."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["Tier"] == "public"]) && alltrue([for s in aws_subnet.private : s.tags["Tier"] == "private"])
    error_message = "Subnets must carry the Tier tag used for discovery."
  }
}

run "private_has_no_internet_route" {
  command = plan

  assert {
    condition     = length(aws_route_table.private.route) == 0
    error_message = "Private route table must not have any route besides local (no NAT, no IGW)."
  }

  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Only the public route table gets the default route."
  }

  assert {
    condition     = length(aws_route_table_association.private) == 2 && length(aws_route_table_association.public) == 2
    error_message = "Each subnet must be associated with its tier route table."
  }
}

run "default_security_group_denies_all" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "Default security group must have no rules."
  }
}

run "rejects_k3s_overlapping_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.42.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_same_az_twice" {
  command = plan

  variables {
    availability_zones = ["ap-northeast-2a", "ap-northeast-2a"]
  }

  expect_failures = [var.availability_zones]
}

run "rejects_non_canonical_k3s_pod_range" {
  command = plan

  variables {
    vpc_cidr = "10.42.1.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_non_canonical_k3s_service_range" {
  command = plan

  variables {
    vpc_cidr = "10.43.200.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_non_canonical_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.0.5.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_non_16_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/8"
  }

  expect_failures = [var.vpc_cidr]
}
