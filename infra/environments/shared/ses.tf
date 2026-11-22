# prod 가입·비밀번호 재설정 메일을 SES로 보낸다(dev·EC2는 Mailpit 유지).
# EKS를 지워도 남아야 하므로 계정 공통 shared 스택에 둔다.
# 발송 자격(SMTP)은 Terraform state에 남기지 않는다: IAM 사용자만 만들고,
# 접근 키·SMTP 비밀번호는 scripts/ses/create-smtp-secret.py가 Secrets Manager에 직접 넣는다.

data "aws_route53_zone" "mail" {
  count        = var.ses_enabled ? 1 : 0
  name         = var.mail_domain
  private_zone = false
}

resource "aws_sesv2_email_identity" "domain" {
  count          = var.ses_enabled ? 1 : 0
  email_identity = var.mail_domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Easy DKIM: SES가 준 토큰 3개를 CNAME으로 게시한다.
resource "aws_route53_record" "dkim" {
  count   = var.ses_enabled ? 3 : 0
  zone_id = data.aws_route53_zone.mail[0].zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.mail_domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# 사용자 지정 MAIL FROM(mail.<domain>): SPF를 우리 도메인으로 맞춰 스팸 분류를 줄인다.
resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  count                  = var.ses_enabled ? 1 : 0
  email_identity         = aws_sesv2_email_identity.domain[0].email_identity
  mail_from_domain       = "mail.${var.mail_domain}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "mail_from_mx" {
  count   = var.ses_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.mail[0].zone_id
  name    = "mail.${var.mail_domain}"
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${var.aws_region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  count   = var.ses_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.mail[0].zone_id
  name    = "mail.${var.mail_domain}"
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com ~all"]
}

# DMARC는 우선 관찰(p=none). 보고서 수신 주소는 두지 않는다(개인 메일 공개 방지).
resource "aws_route53_record" "dmarc" {
  count   = var.ses_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.mail[0].zone_id
  name    = "_dmarc.${var.mail_domain}"
  type    = "TXT"
  ttl     = 1800
  records = ["v=DMARC1; p=none"]
}

# SMTP 전용 IAM 사용자: 이 도메인 identity로, 정해진 발신 주소로만 보낼 수 있다.
resource "aws_iam_user" "ses_smtp" {
  count = var.ses_enabled ? 1 : 0
  name  = "${var.project_name}-ses-smtp"
  path  = "/service/"
}

data "aws_iam_policy_document" "ses_smtp" {
  count = var.ses_enabled ? 1 : 0
  statement {
    sid       = "SendFromProjectDomainOnly"
    actions   = ["ses:SendRawEmail"]
    resources = [aws_sesv2_email_identity.domain[0].arn]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.mail_from_address]
    }
  }
}

resource "aws_iam_user_policy" "ses_smtp" {
  count  = var.ses_enabled ? 1 : 0
  name   = "send-project-mail-only"
  user   = aws_iam_user.ses_smtp[0].name
  policy = data.aws_iam_policy_document.ses_smtp[0].json
}
