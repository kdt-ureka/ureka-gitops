# prod 메일(SES)

dev(EC2·kind·EKS dev)는 Mailpit을 그대로 쓴다. 실제 메일은 **EKS prod auth만** SES로 보낸다(사용성 테스트 가입·비밀번호 재설정).

## 만드는 것 (`infra/environments/shared`, `ses_enabled = true`)
- SES 도메인 identity `magonjal.com` + Easy DKIM(CNAME 3개, Route 53 자동)
- 사용자 지정 MAIL FROM `mail.magonjal.com`(MX·SPF), DMARC `p=none`(관찰, 보고 주소 없음)
- SMTP 전용 IAM 사용자 `ureka-ses-smtp`: `ses:SendRawEmail`만, 이 identity로, 발신 주소 `no-reply@magonjal.com`만
- EKS를 지워도 남는다(shared 스택).

## 순서 (파트장, 내 PC 탭)
1. shared 스택 `terraform plan` → 새로 생기는 것만(ECR·OIDC 변경 0) 확인 → `apply`.
2. SES 콘솔에서 도메인 상태가 **Verified**, DKIM **Successful**이 되는지 확인(수 분~수 시간).
3. SMTP 자격 생성(값은 화면에 안 나옴, 이미 있으면 멈춤):
   ```
   python3 scripts/ses/create-smtp-secret.py --profile ureka-admin --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
   ```
   → Secrets Manager `ureka/eks/prod/ses-smtp`(키 `MAIL_USERNAME`, `MAIL_PASSWORD`).
4. **샌드박스 해제 요청**(콘솔 → SES → 계정 대시보드 → 프로덕션 액세스 요청). 승인 전에는 SES에 인증한 수신 주소로만 보낼 수 있다.
5. prod auth 설정(#43 prod values·#63 ExternalSecret 후속): `MAIL_HOST=email-smtp.ap-northeast-2.amazonaws.com`, `MAIL_PORT=587`, `MAIL_SMTP_AUTH=true`, `MAIL_STARTTLS=true`, `MAIL_FROM=no-reply@magonjal.com`, `MAIL_USERNAME`·`MAIL_PASSWORD`는 위 비밀에서. auth 코드는 이미 `MAIL_USERNAME`·`MAIL_PASSWORD`를 읽는다(`application.yml`).

## 보안 메모
- SMTP 자격은 오래 사는 IAM 접근 키에서 만든 값이다. 권한을 발송·우리 도메인·한 주소로 좁히고 Secrets Manager에만 둔다(Terraform state·Git·화면에 없음). 교체는 새 키 생성 → 비밀 갱신 → auth 재시작 → 옛 키 삭제.
- 수신자 이메일은 개인정보다. 사용성 테스트 뒤 보관·삭제 기준을 정한다.
