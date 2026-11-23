# #63 EC2 dev → EKS dev 비밀 1회 복사(scripts/ec2/copy_eks_dev_secrets.py) 동안만 켜는 쓰기 권한.
# 기본은 꺼짐(정책 없음). 켜기 → 서버에서 복사 → 끄기 순서로, 각각 이 스택 plan/apply로 한다.
# 읽기(GetSecretValue)·목록·삭제는 주지 않는다. 경로는 ureka/eks/dev/ 아래뿐이다(prod·마스터 비밀 제외).
# 기본 KMS 키(aws/secretsmanager)를 쓰므로 kms 권한은 주지 않는다.
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "ec2_copy_eks_dev_secrets" {
  count = var.eks_dev_secret_copy_enabled ? 1 : 0
  name  = "eks-dev-secret-copy"
  role  = data.aws_iam_role.ec2_host.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteEksDevSecretsOnly"
      Effect = "Allow"
      Action = [
        "secretsmanager:CreateSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:TagResource",
      ]
      Resource = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/eks/dev/*"]
    }]
  })
}
