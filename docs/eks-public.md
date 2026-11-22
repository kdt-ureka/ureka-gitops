# EKS prod 공개 입구 (#64 ALB·도메인·인증서, #81 WAF)

EKS **prod**를 `https://magonjal.com`으로 엽니다. dev는 공개하지 않습니다.
이 문서와 코드는 설계·로컬 시험까지입니다. AWS·클러스터에 적용하거나 차단 시험을 한 기록이 아닙니다.
실제 숫자는 아래 [시험 기록](#시험-기록)에 채웁니다.

## 한눈에 보기

```
사용자 ─HTTPS→ Route 53(magonjal.com, www) → ALB(공개 서브넷 2개, WAF ureka-eks-public)
   ├ /api/auth    → ureka-auth     ┐
   ├ /api/chat    → ureka-chat     │ prod 네임스페이스 Pod(대상 ip 방식, 8080)
   ├ /api/content → ureka-content  │ recommend는 연결하지 않음(내부 전용)
   ├ /api/admin   → ureka-ops      │
   └ /            → ureka-frontend ┘
   www.magonjal.com → https://magonjal.com 으로 301
   http(80)       → https(443) 로 돌려보냄
```

| 무엇 | 어디 | 수명 |
|---|---|---|
| 인증서(ACM, apex+www, DNS 검증) | `infra/environments/eks/public.tf` | EKS 스택과 같이 생성·삭제 |
| WAF(관리자 IP 제한·비회원 발급 제한) | 〃 | 〃 |
| 컨트롤러 IRSA 역할·정책 | 〃 + `policies/aws-load-balancer-controller-v3.6.3.json` | 〃 |
| Route 53 별칭 레코드(apex·www) | 〃 (2단계) | 〃 |
| AWS Load Balancer Controller | `argocd/eks/aws-load-balancer-controller-app.yaml` (차트 3.6.3) | 클러스터와 같이 |
| 공개 Ingress·ALB 허용 NetworkPolicy | `charts/ureka-public-ingress`, `environments/eks/prod/public-ingress.yaml`, `argocd/eks/prod-public-ingress-app.yaml` | 〃 |
| ALB 자체 | 컨트롤러가 Ingress에서 만듦 | **Ingress를 지워야 지워짐** |

## 정한 것과 이유

- **CloudFront는 이번에 넣지 않습니다.** 설계서는 CloudFront → ALB지만, 넣으면 일이 많아집니다(us-east-1 인증서·WAF, ALB가 CloudFront 요청만 받게 막기, 실제 접속 IP 처리). 목요일 사용성 테스트에는 단순한 쪽을 골랐습니다. CloudFront는 후속으로 다시 봅니다.
- **IP·계정 ID를 Git에 쓰지 않습니다.**
  - 관리자 IP 허용 목록은 Ingress 주석이 아니라 WAF IP 목록에 둡니다. 값은 비공개 `terraform.tfvars`의 `admin_path_allowed_cidrs`입니다.
  - 인증서는 ARN 대신 Ingress `tls.hosts`로 ACM에서 찾습니다.
  - WAF는 ARN 대신 이름(`ureka-eks-public`)으로 지정합니다.
  - 컨트롤러 역할 ARN의 계정 ID만 등록 스크립트가 넣습니다.
- **강제 설정은 Ingress가 아니라 클래스에 둡니다.** 컨트롤러의 IngressClassParams가 `alb` 클래스를 쓰는 모든 Ingress에 다음을 강제합니다. Ingress 주석으로는 바꿀 수 없습니다.
  - prod 네임스페이스에서만 쓸 수 있음
  - 인터넷용 ALB 하나(group `ureka-prod`), 대상 ip
  - TLS 정책 `ELBSecurityPolicy-TLS13-1-2-2021-06`, 80→443
  - WAF `ureka-eks-public`
  - idle timeout 120초(채팅 SSE), 잘못된 헤더 버림
- **관리자 경로 규칙(WAF 우선순위 순서)**
  1. `GET /api/admin/v1/public-notice`(공개 장애 공지)는 누구나 됩니다.
  2. `/admin…` 또는 `/api/admin…`은 허용 IP가 아니면 403입니다. URL 디코딩과 소문자 변환 뒤에 비교합니다.
  3. 허용 목록이 비어 있으면 아무도 못 들어갑니다(안전 쪽 기본값). 관리자 API는 이와 별도로 ops가 `ADMIN` 토큰도 확인합니다.
- **비회원 토큰 발급 제한(#81, 위협 모델 T1 주 방어 ②)**
  - `POST /api/auth/v1/guest-tokens…`를 IP별로 **5분에 20회**까지 허용하고, 넘으면 **429**를 돌려줍니다.
  - tfvars `guest_token_rate_limit`·`guest_token_rate_window_sec`로 바꿀 수 있습니다.
  - WAF 공식 제한: 평가 창은 60·120·300·600초만, 한도는 최소 10입니다.
  - WAF는 추정으로 세기 때문에 정확히 21번째에서 바로 막히지는 않습니다. 반영이 몇십 초 늦을 수 있습니다.
  - 사무실 하나처럼 여러 사람이 같은 공인 IP를 쓰면 같이 셉니다. 사용성 테스트는 원격이라 사람마다 IP가 다를 것으로 봅니다.
  - 이 규칙 하나로 분산 봇을 다 막지는 못합니다. 그래서 auth#44(봇 확인)와 chat#51(공유 상한)이 함께 있어야 합니다.
- **WAF 요청 원문 로그는 켜지 않습니다.** 비용과 개인정보 때문입니다. CloudWatch 지표와 샘플 요청만 봅니다.
- **수명 주기를 EKS와 맞춥니다.** WAF는 EKS를 꺼도 남겨 두면 과금되므로 EKS 스택 안에 둡니다. ALB가 남아 있으면 WAF를 지울 수 없어서 destroy가 멈춥니다.
  - 그래서 운영 도구(`scripts/eks/operate.py`)의 destroy 사전 검사가, 이 클러스터 컨트롤러가 만든 ALB가 남아 있으면 plan 전에 멈추게 했습니다.
- **컨트롤러 권한**
  - IRSA 신뢰는 `kube-system:aws-load-balancer-controller` 하나뿐입니다.
  - 정책은 v3.6.3 공식 `iam_policy.json`을 그대로 씁니다(sha256을 시험에서 고정).
  - WAF를 이름으로 찾느라 `wafv2:ListWebACLs` 하나만 더했습니다(공식 주석 문서가 요구).
  - Shield·옛 WAF·Service 웹훅은 끕니다.
- **IMDS hop 1이라 값을 직접 줍니다.** Pod가 IMDS로 리전·VPC를 알 수 없어서 `region`·`clusterName`·`vpcTags`(network 스택 태그)를 직접 넣습니다. VPC ID 대신 태그를 써서 Git에 ID를 남기지 않습니다.
- **서브넷 태그는 이미 있습니다.** network 모듈이 public 서브넷에 `kubernetes.io/role/elb`를 붙여 두었습니다. network 변경은 필요 없습니다.

## 비용 (EKS를 켠 동안만, USD, 세금 제외)

AWS 가격표에서 확인한 것은 미국 리전 예시값뿐입니다. 서울 요율은 계산기로 다시 확인합니다(서울이 조금 비쌀 수 있음).

| 항목 | 단가(가격표 예시) | 하루(24시간) |
|---|---|---:|
| ALB | 시간당 $0.0225 + LCU 시간당 $0.008(시연 규모면 1 LCU 미만) | 약 $0.55~0.75 |
| WAF Web ACL | 월 $5.00(시간 단위로 나눠 청구) | 약 $0.17 |
| WAF 규칙 3개 | 규칙당 월 $1.00 | 약 $0.10 |
| WAF 요청 | 100만 건당 $0.60 | 거의 0 |
| ACM 공개 인증서 | 무료 | 0 |
| Route 53 | 호스팅 영역 월 $0.50(이미 내는 중), 별칭 조회 무료 | 0 |
| 합계 | | **약 $0.8~1.0** |

4일을 켜면 약 $3.5~4입니다(원화로 약 5천~6천 원). EKS 본체는 [eks.md](eks.md) 비용 표(하루 약 $9)를 따로 봅니다.

## 켜기 순서 (파트장이 직접, 보안/교차 검토와 파트장 승인 뒤)

준비할 것
- EKS·Argo CD가 떠 있음([eks.md](eks.md), [eks-argocd.md](eks-argocd.md))
- prod 네임스페이스(#62)·Secret(#63)·서비스(#43)가 Ready
- RDS가 가동 중

1. **Terraform 1단계**
   - 비공개 `infra/environments/eks/terraform.tfvars`에 다음을 넣습니다.
     - `public_enabled = true`
     - `admin_path_allowed_cidrs = ["<관리자 공인 IP>/32", …]`
   - 공통 운영 도구로 plan → 검토 → apply합니다. 새로 생기는 것: 인증서·검증 CNAME 2개, WAF·IP 목록, 컨트롤러 역할·정책.
   - plan에서 확인할 것: 생성만 있고 RDS·network 변경이 없는지, WAF 규칙 3개.
   - apply 뒤 인증서 상태가 `ISSUED`인지 확인합니다(보통 몇 분).
2. **컨트롤러 등록·Sync**
   ```sh
   export UREKA_EXPECTED_ACCOUNT_ID=...   # 승인된 로컬 설정에서. 화면·채팅에 쓰지 않음
   python3 scripts/eks/register_lbc_app.py check --profile ureka-admin
   python3 scripts/eks/register_lbc_app.py apply --profile ureka-admin --confirm-cluster ureka-eks
   ```
   Argo CD에서 `aws-load-balancer-controller`를 직접 Sync합니다. Healthy와 Pod 2개 Ready를 확인합니다.
   `kubectl -n kube-system logs deploy/aws-load-balancer-controller`에 권한 오류가 없는지 봅니다.
3. **공개 Ingress 등록·Sync (여기서 ALB 과금 시작)**
   ```sh
   kubectl --context ureka-eks apply -f argocd/eks/prod-public-ingress-app.yaml
   ```
   Argo CD에서 `ureka-prod-public-ingress`를 직접 Sync합니다. `kubectl -n prod describe ingress ureka-public` 이벤트에서 ALB 생성과 오류 여부를 봅니다.
4. **WAF 연결 확인 (DNS 전에 꼭)**
   ```sh
   python3 scripts/eks/register_lbc_app.py verify --profile ureka-admin
   ```
   "WAF 연결됨"이 아니면 **멈추고** 공개 Ingress Application을 지웁니다. 컨트롤러가 이름으로 WAF를 못 찾았을 때 어떻게 동작하는지는 공식 문서에 없습니다. 그래서 이 확인을 반드시 합니다.
5. **Terraform 2단계 (DNS)**
   - tfvars에 `public_dns_enabled = true`를 넣고 plan → apply합니다.
   - 새로 생기는 것: apex·www A 별칭 레코드 2개.
6. 아래 [공개 전 게이트](#공개-전-게이트)를 모두 통과한 뒤에만 주소를 공유합니다.

## 공개 전 게이트

주소를 팀 밖(PD팀 사용성 테스트 포함)에 공유하기 전에 모두 체크합니다. 하나라도 안 되면 공유하지 않습니다.

- [ ] **auth#44 비회원 발급 봇 확인**이 서버에서 검증됩니다(Turnstile Siteverify 등). 위젯만 있고 서버가 검증하지 않으면 통과가 아닙니다. 이 이미지가 prod에 있습니다.
- [ ] **chat#51 비회원 장르 추천 공유 상한·긴급 중단**이 prod에 반영됐고, 긴급 중단을 시험했습니다.
- [ ] **WAF 발급 제한 차단 시험**: 아래 시험 1의 숫자를 기록했습니다(몇 번째부터 429, 풀리는 데 걸린 시간).
- [ ] **관리자 경로 IP 제한 시험**: 아래 시험 2. 허용 안 된 IP에서는 403, 허용 IP에서는 정상, 공지 조회는 누구나 200입니다.
- [ ] **SES 실제 메일 발송 확인**(가입 흐름이 사용성 테스트에 들어감)
  - SES 도메인 인증(DKIM)이 끝났습니다. DKIM 레코드는 EKS 스택에 두지 않습니다(EKS를 지울 때 같이 지워지면 안 됨).
  - 샌드박스 해제(프로덕션 액세스)를 받았습니다. 해제 전이라면 참가자 주소를 모두 미리 인증해 두었습니다.
  - prod auth가 SES SMTP 자격으로 보냅니다(Mailpit이 아님). 자격은 Secrets Manager → ESO로 들어갑니다.
  - 팀원이 아닌 주소로 실제 가입 인증 메일을 받았고, 받는 데 걸린 시간을 기록했습니다.
- [ ] **HTTPS 전제 설정**
  - prod auth `COOKIE_SECURE=true`(base values는 dev용 `false`라 #43 prod values에서 덮어씀)
  - 브라우저에서 로그인 → 새로고침 → 리프레시 쿠키(Secure·Lax)가 유지됩니다.
- [ ] `http://magonjal.com` → https, `https://www.magonjal.com` → `https://magonjal.com`(301)으로 갑니다. 인증서 이름이 맞습니다.
- [ ] `https://magonjal.com/api/recommend/…`처럼 내부 경로를 부르면 recommend에 닿지 않습니다(화면 HTML이나 404가 나옴).
- [ ] ALB 주소(`*.elb.amazonaws.com`)로 바로 부르면 404입니다(호스트 이름 규칙만 있음).
- [ ] 비용 알림(예산)이 켜져 있고, 끄는 날짜·담당자를 정했습니다.

## 시험 방법

### 시험 1: 비회원 발급 제한 (#81)

관리자 IP가 아닌 곳(휴대폰 핫스팟 등)에서 실행합니다. 시험 중에는 그 IP의 정상 발급도 막힙니다.

```sh
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST https://magonjal.com/api/auth/v1/guest-tokens \
    -H 'Content-Type: application/json' -d '{}')
  echo "$(date +%T) $i $code"; sleep 2
done
```

- 응답 본문(토큰)은 저장하거나 공유하지 않습니다.
- auth#44가 들어가면 봇 확인 값이 없어 4xx가 나올 수 있습니다. WAF는 앱 응답과 상관없이 요청 수를 셉니다. 429가 나오는 시점만 기록합니다.
- 기록할 것: 처음 429가 나온 회차와 시각, 마지막 시도 뒤 다시 200(또는 앱 4xx)으로 돌아온 시각, WAF 콘솔의 `rate-limit-guest-tokens` 지표·샘플 요청.
- 시험한 뒤 IP 하나에서 생긴 비회원 actor 수를 확인합니다(DB 누적, 위협 모델 T1).

### 시험 2: 관리자 경로 IP 제한 (#64)

```sh
# 허용 안 된 IP에서
curl -s -o /dev/null -w '%{http_code}\n' https://magonjal.com/admin                    # 403
curl -s -o /dev/null -w '%{http_code}\n' https://magonjal.com/api/admin/v1/incidents   # 403 (경로는 ops 기준으로 바꿔서)
curl -s -o /dev/null -w '%{http_code}\n' https://magonjal.com/api/%61dmin/v1/incidents # 403 (인코딩 우회)
curl -s -o /dev/null -w '%{http_code}\n' https://magonjal.com/api/admin/v1/public-notice  # 200 (예외)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://magonjal.com/api/admin/v1/public-notice  # 403 (GET만 예외)
# 허용 IP에서: /admin 화면이 열리고, ADMIN 토큰 없이 부르는 관리자 API는 ops가 401/403
```

## 끄기 순서

[eks.md 끄기](eks.md) 앞에 다음을 넣습니다.

1. 공지·참가자 안내 뒤 tfvars에서 `public_dns_enabled = false`로 바꾸고 plan → apply합니다. 레코드 2개만 삭제되는지 확인합니다. 이 단계는 생략하고 마지막 destroy에 맡겨도 됩니다.
2. Argo CD에서 `ureka-prod-public-ingress` Application을 지웁니다(리소스 함께 삭제). 컨트롤러가 ALB·대상 그룹·자기가 만든 SG를 지울 때까지 **컨트롤러는 살려 둡니다.**
3. AWS 콘솔이나 CLI에서 `elbv2.k8s.aws/cluster=ureka-eks` 태그 ALB가 0개인지 확인합니다. 운영 도구 destroy plan도 남아 있으면 멈춥니다.
4. 그다음 기존 eks.md 끄기 순서(앱 정리 → data SG 참조 제거 → destroy)를 따릅니다. destroy가 인증서·WAF·IP 목록·컨트롤러 역할·레코드를 같이 지웁니다.
5. 잔존 확인: ALB 0, WAF Web ACL `ureka-eks-public` 없음, 인증서 없음(검증 CNAME도 삭제), Route 53 영역은 남음(Terraform 밖).

## 알려진 한계·후속

- CloudFront·Shield·AWS 관리형 규칙(Common Rule Set)은 없습니다. 관리형 규칙은 채팅 글이 잘못 막힐 수 있어서 시험 뒤에 다시 봅니다.
- WAF IP 목록은 IPv4 /32만 받습니다. 관리자 IP가 바뀌면 tfvars를 고치고 apply합니다.
- 컨트롤러가 대상 ip 방식으로 노드 SG에 ALB SG 인바운드 규칙을 직접 추가합니다. Terraform은 개별 규칙 리소스를 써서 이 규칙을 되돌리지 않습니다.
- Pod readiness gate(배포 중 ALB 대상 준비 확인)는 prod 네임스페이스 라벨이 필요합니다. 네임스페이스는 #62 담당이라 후속으로 둡니다. 지금은 롤링 배포 때 짧은 502가 날 수 있습니다.
- Argo CD AppProject는 지금 `default`입니다. #43이 AppProject를 나누면 두 Application을 옮깁니다.
- 컨트롤러 차트를 올릴 때는 차트 버전, `policies/` 정책 파일, 정책 sha256 시험, 이 문서를 같이 올립니다.

## 로컬 검증 (AWS·클러스터 불필요)

```sh
(cd infra/environments/eks && terraform init -backend=false && terraform test)   # mock provider
bash scripts/test-eks-public.sh          # 공개 Ingress·컨트롤러 앱 렌더링·값 대조
python3 -m unittest discover -s tests/eks # 등록·확인 스크립트, destroy ALB 검사
bash scripts/check-forbidden-files.sh
```

## 시험 기록

| 항목 | 날짜 | 결과 | 비고 |
|---|---|---|---|
| 1단계 apply(인증서 ISSUED까지) | 미실행 | | |
| ALB 생성(Ingress Sync → active) | 미실행 | | |
| WAF 연결 verify | 미실행 | | |
| 발급 제한: 처음 429 회차·풀린 시간 | 미실행 | | |
| 관리자 경로 403·공지 200 | 미실행 | | |
| SES 실제 메일 수신 시간 | 미실행 | | |
| Ingress 삭제 → ALB 0 | 미실행 | | |

참고: [ALB 컨트롤러 주석](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/), [IngressClassParams](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/ingress_class/), [인증서 찾기](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/cert_discovery/), [WAF 요청 수 제한 설정](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-high-level-settings.html), [WAF 요금](https://aws.amazon.com/waf/pricing/), [ELB 요금](https://aws.amazon.com/elasticloadbalancing/pricing/).
