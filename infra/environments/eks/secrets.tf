# #63 ESO 리더 IRSA. 환경(dev·prod)마다 역할 하나, 그 환경 경로의 비밀만 읽는다.
# - ESO 컨트롤러 자신의 서비스계정에는 AWS 역할을 주지 않는다. 네임스페이스 SecretStore가
#   그 네임스페이스의 리더 서비스계정 토큰으로 이 역할을 맡는다(dev 리더는 prod 경로를 못 읽는다).
# - 비밀 자체(값·컨테이너)는 이 스택이 만들지 않는다. EKS를 지워도 남아야 하고 값이 state에 남으면 안 된다.
#   dev는 scripts/ec2/copy_eks_dev_secrets.py, prod는 scripts/eks/seed_prod_secrets.py가 만든다(docs/eks-secrets.md).
# - 기본 KMS 키(aws/secretsmanager)를 쓰므로 kms 권한은 주지 않는다. 고객 관리 키로 바꾸면 재검토한다.
data "aws_caller_identity" "current" {}

locals {
  eso_reader_service_account = "ureka-secrets-reader"
  eso_reader_environments    = toset(["dev", "prod"])
  # 마지막 '/'까지 고정: ureka/eks/dev/* 는 ureka/eks/devx… 나 ureka/eks/prod/… 와 겹치지 않는다.
  eso_secret_arn_prefix = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/eks"
}

resource "aws_iam_role" "eso_reader" {
  for_each = local.eso_reader_environments
  name     = "${local.name}-eso-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${local.oidc_host}:sub" = "system:serviceaccount:${each.key}:${local.eso_reader_service_account}"
        "${local.oidc_host}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}

resource "aws_iam_role_policy" "eso_reader" {
  for_each = local.eso_reader_environments
  name     = "read-${each.key}-secrets"
  role     = aws_iam_role.eso_reader[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadOwnEnvironmentSecretsOnly"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = ["${local.eso_secret_arn_prefix}/${each.key}/*"]
    }]
  })
}
