# EKS prod 공개 입구 (#64 ALB·도메인·인증서, #81 WAF)

EKS **prod**를 `https://ureka.magonjal.com`으로 엽니다. dev는 공개하지 않습니다.
apex(`magonjal.com`)와 `www`는 지금 공개하지 않습니다. 레코드·인증서·Ingress 규칙을 만들지 않습니다. 같은 도메인의 SES 발신 주소(no-reply)는 이 문서와 관계없이 그대로 씁니다.
이 문서와 코드는 설계·로컬 시험까지입니다. AWS·클러스터에 적용하거나 차단 시험을 한 기록이 아닙니다.
실제 숫자는 아래 [시험 기록](#시험-기록)에 채웁니다.

## 한눈에 보기

```
사용자 ─HTTPS→ Route 53(ureka.magonjal.com, magonjal.com 영역 안 별칭)
  → ALB(공개 서브넷 2개)
      입구 SG ureka-eks-alb-public: 처음엔 시험자 /32만 → 게이트 통과·승인 뒤 인터넷 전체
      WAF ureka-eks-public: 모호한 경로 400 → 공지 GET 허용 → 관리자 경로 IP 제한 → 비회원 발급 IP별 제한
   ├ /api/auth    → ureka-auth     ┐
   ├ /api/chat    → ureka-chat     │ prod 네임스페이스 Pod(대상 ip 방식, 8080)
   ├ /api/content → ureka-content  │ recommend는 연결하지 않음(내부 전용)
   ├ /api/admin   → ureka-ops      │
   └ /            → ureka-frontend ┘
   http(80) → https(443). 다른 Host(apex·ALB 주소 등)는 404
```

| 무엇 | 어디 | 수명 |
|---|---|---|
| 인증서(ACM, `ureka.magonjal.com` 하나, DNS 검증) | `infra/environments/eks/public.tf` | EKS 스택과 같이 생성·삭제 |
| ALB 입구 SG·시험자 목록(prefix list) | 〃 | 〃 |
| WAF(규칙 4개)·관리자 IP 목록 | 〃 | 〃 |
| 컨트롤러 IRSA 역할·정책 | 〃 + `policies/aws-load-balancer-controller-v3.6.3.json` | 〃 |
| Route 53 별칭 레코드(`ureka.magonjal.com`) | 〃 (2단계) | 〃 |
| AWS Load Balancer Controller | `argocd/eks/aws-load-balancer-controller-app.yaml` (차트 3.6.3) | 클러스터와 같이 |
| 공개 Ingress(+ 기본 꺼진 ALB 허용 NetworkPolicy) | `charts/ureka-public-ingress`, `environments/eks/prod/public-ingress.yaml`, `argocd/eks/prod-public-ingress-app.yaml` | 〃 |
| ALB 자체 | 컨트롤러가 Ingress에서 만듦 | **Ingress를 지워야 지워짐** |

## 정한 것과 이유

- **CloudFront는 이번에 넣지 않습니다.** 설계서는 CloudFront → ALB입니다. 하지만 넣으면 us-east-1 인증서·WAF, ALB가 CloudFront 요청만 받게 막기, 실제 접속 IP 처리까지 해야 합니다. 목요일 사용성 테스트에는 단순한 쪽을 골랐고, CloudFront는 후속으로 다시 봅니다.
- **단계별로 엽니다.** ALB 입구 SG를 Terraform이 직접 만들고, Ingress는 이 SG를 이름으로만 씁니다. SG를 못 찾으면 컨트롤러가 ALB를 만들지 않습니다.
  - 처음(`public_access_mode = "testers"`)에는 80/443을 시험자 /32 목록에서만 받습니다. 목록이 비면 아무도 못 들어옵니다.
  - WAF 연결·차단 시험·auth#44·chat#51·쿠키·메일 확인은 모두 이 제한된 입구에서 합니다.
  - 게이트를 통과하고 파트장이 승인하면 `"open"`으로 바꿔 별도 apply로 인터넷 전체 규칙을 더합니다(시험자 규칙은 유지해서 plan이 생성만 됨).
  - DNS가 없다거나 호스트가 달라 404가 나는 것은 접근 통제가 아닙니다. 그래서 SG로 막습니다.
- **IP·계정 ID를 Git에 쓰지 않습니다.**
  - 시험자 목록·관리자 목록은 비공개 `terraform.tfvars`(`alb_tester_cidrs`, `admin_path_allowed_cidrs`)에만 둡니다.
  - 인증서는 ARN 대신 Ingress `tls.hosts`로 ACM에서 찾습니다.
  - WAF는 이름(`ureka-eks-public`)으로, SG도 이름으로 지정합니다.
  - 컨트롤러 역할 ARN의 계정 ID만 등록 스크립트가 메모리에서 넣습니다.
  - 등록·확인 스크립트는 계정 ID가 든 ALB ARN을 AWS CLI 명령 인자가 아니라 0600 임시 JSON 파일(`--cli-input-json file://`, 호출 뒤 삭제)로 넘깁니다. 단 VPC ID·SG 이름은 인자로 갑니다.
- **강제 설정은 Ingress가 아니라 클래스에 둡니다.** 컨트롤러의 IngressClassParams가 `alb` 클래스를 쓰는 모든 Ingress에 강제합니다.
  - prod 네임스페이스에서만 쓸 수 있음
  - 인터넷용 ALB 하나(group `ureka-prod`), 대상 ip
  - TLS 정책 `ELBSecurityPolicy-TLS13-1-2-2021-06`, 80→443
  - WAF `ureka-eks-public`
  - idle timeout 120초(채팅 SSE), 잘못된 헤더 버림
- **WAF 규칙 (우선순위 순서)**
  1. **모호한 경로 거부(400)**: 이중 슬래시, `/./`, `/../`(경로 끝 포함), 인코딩된 `.`·`/`·`\`·`%`(`%2e`·`%2f`·`%5c`·`%25`), `%00`, `\`, `;`. WAF가 검사하는 경로와 ALB·앱(Spring)·frontend nginx가 해석하는 경로가 달라지는 것을 처음부터 막습니다. 정상 화면·API 경로에는 이런 형식이 없습니다. AWS WAF 정규식은 괄호(그룹)를 지원하지 않아 대안(`|`)만 씁니다.
  2. **공지 조회**: `GET /api/admin/v1/public-notice`는 누구나 됩니다. 변환 없이 정확히 같은 경로일 때만입니다.
  3. **관리자 경로**: `/admin…`·`/api/admin…`은 허용 IP가 아니면 403입니다. URL 디코딩 → 경로 정규화 → 소문자로 바꾼 뒤 비교해서, 앱에 닿는 경로보다 넓게 잡습니다. 허용 목록이 비면 아무도 못 들어갑니다. 관리자 API는 이와 별도로 ops가 `ADMIN` 토큰도 확인합니다.
  4. **비회원 토큰 발급**(#81, 위협 모델 T1 주 방어 ②): `POST /api/auth/v1/guest-tokens…`(같은 변환 뒤 비교)를 IP별 **5분 20회**까지 허용하고, 넘으면 **429**입니다.
     - tfvars `guest_token_rate_limit`·`guest_token_rate_window_sec`로 조정합니다. WAF 공식 제한은 평가 창 60·120·300·600초, 한도 최소 10입니다.
     - WAF는 추정으로 세서 정확히 21번째에서 막히지는 않습니다. 반영이 몇십 초 늦을 수 있습니다.
     - 같은 공인 IP(공유 NAT)를 쓰는 참가자는 한도를 함께 씁니다.
     - 이 규칙 하나로 분산 봇을 다 막지 못합니다. auth#44(봇 확인)·chat#51(공유 상한)과 함께 있어야 합니다.
- **WAF 요청 샘플링·요청 로그는 끕니다.** 샘플에는 Cookie·Authorization 헤더가 들어갈 수 있습니다. 대신 CloudWatch 지표(규칙별 차단 수)로 봅니다.
- **수명 주기를 EKS와 맞춥니다.** WAF는 EKS를 꺼도 남겨 두면 과금되므로 EKS 스택 안에 둡니다. ALB가 남아 있으면 WAF·입구 SG를 지울 수 없어 destroy가 멈춥니다.
  - 그래서 운영 도구(`scripts/eks/operate.py`)의 destroy 사전 검사가, 이 클러스터 컨트롤러가 만든 ALB가 남아 있으면 plan 전에 멈춥니다.
- **ACM 검증 레코드는 덮어쓰지 않습니다**(`allow_overwrite = false`). 같은 이름 레코드가 이미 있으면 apply가 멈춥니다. 다른 곳의 레코드를 이 단기 스택이 가져갔다가 destroy 때 지우지 않게 하기 위해서입니다. 지난번 destroy가 지운 뒤라면 충돌이 없습니다.
- **ALB → Pod NetworkPolicy는 기본 꺼짐**(`albNetworkPolicy.enabled=false`).
  - NetworkPolicy가 Pod를 고르면 그 Pod는 격리됩니다. 이 정책만 먼저 넣으면 ALB 헬스 체크는 통과해도 chat → content 같은 내부 호출이 막힙니다.
  - 지금 prod에는 NetworkPolicy가 없어서 ALB → Pod가 열려 있습니다. prod 기본 거부·내부 허용 정책(#49, EC2 dev와 같은 표)을 넣을 때 같이 켜고, 실제 흐름까지 시험합니다.
- **컨트롤러 권한**
  - IRSA 신뢰는 `kube-system:aws-load-balancer-controller` 하나뿐입니다.
  - 정책은 v3.6.3 공식 `iam_policy.json`을 그대로 씁니다(sha256을 시험에서 고정).
  - WAF를 이름으로 찾느라 `wafv2:ListWebACLs` 하나만 더했습니다(목록 작업이라 리소스 제한 불가).
  - Shield·옛 WAF·Service 웹훅은 끕니다.
  - SG를 직접 지정하면 컨트롤러가 노드 쪽 허용을 안 하므로 `manage-backend-security-group-rules: "true"`로 백엔드 SG 규칙만 맡깁니다.
- **IMDS hop 1이라 값을 직접 줍니다.** `region`·`clusterName`·`vpcTags`(network 스택 태그)를 넣습니다. VPC ID 대신 태그를 써서 Git에 ID를 남기지 않습니다.
- **서브넷 태그는 이미 있습니다.** network 모듈이 public 서브넷에 `kubernetes.io/role/elb`를 붙여 두어 network 변경은 필요 없습니다.

## 비용 (EKS를 켠 동안만, USD, 세금 제외)

AWS 가격표에서 확인한 것은 미국 리전 예시값뿐입니다. 서울 요율·실청구액은 계산기와 청구서로 다시 확인합니다(서울이 조금 비쌀 수 있음).

| 항목 | 단가(가격표 예시) | 하루(24시간) |
|---|---|---:|
| ALB | 시간당 $0.0225 + LCU 시간당 $0.008(시연 규모면 1 LCU 미만) | 약 $0.55~0.75 |
| ALB 공인 IPv4 2개(서브넷당 1개) | 주소당 시간당 $0.005 | 약 $0.24 |
| WAF Web ACL | 월 $5.00(시간 단위로 나눠 청구) | 약 $0.17 |
| WAF 규칙 4개 | 규칙당 월 $1.00 | 약 $0.13 |
| WAF 요청 | 100만 건당 $0.60 | 거의 0 |
| ACM 공개 인증서·prefix list·SG | 무료 | 0 |
| Route 53 | 호스팅 영역 월 $0.50(이미 내는 중), 별칭 조회 무료 | 0 |
| 합계 | | **약 $1.1~1.3** |

4일(96시간)을 켜면 약 $4.5~5입니다(원화 약 6천~7천 원). EKS 본체는 [eks.md](eks.md) 비용 표(하루 약 $9)를 따로 봅니다.

## 켜기 순서 (파트장이 직접, 보안/교차 검토와 파트장 승인 뒤)

준비할 것
- EKS·Argo CD가 떠 있음([eks.md](eks.md), [eks-argocd.md](eks-argocd.md))
- prod 네임스페이스(#62)·Secret(#63)·서비스(#43)가 Ready
- RDS가 가동 중

1. **Terraform 1단계 (시험자만)**
   - 비공개 `infra/environments/eks/terraform.tfvars`에 다음을 넣습니다.
     - `public_enabled = true`
     - `public_access_mode = "testers"`
     - `alb_tester_cidrs`: 관리자 IP + **관리자 목록에 없는 시험 IP** 하나 이상(휴대폰 핫스팟 등, 관리자 차단 시험용)
     - `admin_path_allowed_cidrs`: 관리자 IP만
   - 공통 운영 도구로 plan → 검토 → apply합니다. 새로 생기는 것: 인증서·검증 CNAME 1개, 입구 SG·규칙(80/443 시험자 목록, 8080 VPC 방향)·prefix list, WAF·IP 목록, 컨트롤러 역할·정책.
   - plan에서 확인할 것: 생성만 있는지, `0.0.0.0/0` 입구 규칙이 없는지, RDS·network 변경이 없는지.
   - 인증서 `ISSUED`를 확인합니다(보통 몇 분). 검증 레코드가 이미 있어 apply가 멈추면, 그 레코드가 어디서 왔는지 확인한 뒤 진행합니다.
2. **컨트롤러 등록·Sync**
   ```sh
   export UREKA_EXPECTED_ACCOUNT_ID=...   # 승인된 로컬 설정에서. 화면·채팅에 쓰지 않음
   python3 scripts/eks/register_lbc_app.py check --profile ureka-admin
   python3 scripts/eks/register_lbc_app.py apply --profile ureka-admin --confirm-cluster ureka-eks
   ```
   Argo CD에서 `aws-load-balancer-controller`를 직접 Sync합니다.
   - 확인할 것: Healthy, Pod 2개 Ready, IngressClass `alb`·IngressClassParams `ureka-prod-public` 생성, 웹훅 Ready.
   - `kubectl -n kube-system logs deploy/aws-load-balancer-controller`에 권한 오류가 없는지 봅니다.
3. **공개 Ingress 등록·Sync (여기서 ALB 과금 시작, 아직 시험자만 접근)**
   ```sh
   kubectl --context ureka-eks apply -f argocd/eks/prod-public-ingress-app.yaml
   ```
   Argo CD에서 `ureka-prod-public-ingress`를 직접 Sync합니다. `kubectl -n prod describe ingress ureka-public` 이벤트에서 ALB 생성과 오류 여부를 봅니다.
4. **입구 확인**
   ```sh
   python3 scripts/eks/register_lbc_app.py verify --profile ureka-admin
   ```
   - 확인 내용: ALB가 정확히 1개, 입구 SG `ureka-eks-alb-public` 연결, WAF `ureka-eks-public` 연결.
   - 하나라도 아니면 **멈추고** 공개 Ingress Application을 지웁니다. 이름으로 WAF를 못 찾았을 때 컨트롤러가 어떻게 동작하는지는 공식 문서에 없어서 반드시 확인합니다.
5. **Terraform 2단계 (DNS)**
   - tfvars에 `public_dns_enabled = true`를 넣고 plan → apply합니다. 새로 생기는 것: `ureka.magonjal.com` A 별칭 레코드 1개.
   - plan에 레코드가 없고 `public_alb_found` 경고가 나오면 ALB를 못 찾은 것이니 4단계로 돌아갑니다.
   - DNS가 생겨도 입구는 아직 시험자만입니다.
6. **[공개 전 게이트](#공개-전-게이트)**를 시험자 IP에서 모두 통과하고 결과를 기록합니다.
7. **Terraform 3단계 (공개, 파트장 승인 뒤)**
   - 공개 직전에 4단계 `verify`를 다시 실행합니다.
   - tfvars에 `public_access_mode = "open"`을 넣고 plan → apply합니다.
   - 공통 운영 도구로 plan → 검토 → apply합니다. plan에는 `0.0.0.0/0` 80/443 규칙 2개 **생성만** 나와야 합니다(시험자 규칙은 그대로 둠). 삭제·변경이 보이면 멈춥니다.
   - 그 뒤 주소를 공유합니다.

## 공개 전 게이트

시험자 입구(6단계)에서 모두 체크합니다. 하나라도 안 되면 `open`으로 바꾸지 않고, 주소를 팀 밖(PD팀 사용성 테스트 포함)에 공유하지 않습니다.

- [ ] **auth#44 비회원 발급 봇 확인**이 서버에서 검증됩니다(Turnstile Siteverify 등). 위젯만 있고 서버가 검증하지 않으면 통과가 아닙니다. 이 이미지가 prod에 있습니다.
- [ ] **chat#51 비회원 장르 추천 공유 상한·긴급 중단**이 prod에 반영됐고, 긴급 중단을 시험했습니다.
- [ ] **WAF 발급 제한 차단 시험**: 아래 시험 1의 숫자를 기록했습니다(몇 번째부터 429, 풀리는 데 걸린 시간, WAF 지표).
- [ ] **관리자 경로 IP 제한 시험**: 아래 시험 2. 관리자 목록에 없는 시험 IP에서는 403, 관리자 IP에서는 정상, 공지 GET은 누구나 200입니다.
- [ ] **경로 정규화 시험**: 아래 시험 3. 모호한 경로는 400이고, 대소문자·인코딩을 바꾼 관리자·발급 경로가 우회되지 않습니다.
- [ ] **내부 흐름**: 공개 주소로 로그인 → 채팅 → 추천 → 작품 상세까지 실제로 됩니다(chat → recommend → content 내부 호출 포함).
  - ALB NetworkPolicy를 켰다면 prod 내부 허용 정책도 있는 상태에서 다시 확인합니다.
- [ ] **SES 실제 메일 발송 확인**(가입 흐름이 사용성 테스트에 들어감)
  - SES 도메인 인증(DKIM)이 끝났습니다. DKIM 레코드는 EKS 스택에 두지 않습니다(EKS를 지울 때 같이 지워지면 안 됨).
  - 샌드박스 해제(프로덕션 액세스)를 받았습니다. 해제 전이라면 참가자 주소를 모두 미리 인증해 두었습니다.
  - prod auth가 SES SMTP 자격으로 보냅니다(Mailpit이 아님). 자격은 Secrets Manager → ESO로 들어갑니다.
  - 팀원이 아닌 주소로 실제 가입 인증 메일을 받았고, 받는 데 걸린 시간을 기록했습니다.
- [ ] **HTTPS 전제 설정**
  - prod auth `COOKIE_SECURE=true`(base values는 dev용 `false`라 #43 prod values에서 덮어씀)
  - 브라우저에서 로그인 → 새로고침 → 리프레시 쿠키(Secure·Lax)가 유지됩니다.
- [ ] `http://ureka.magonjal.com` → https로 갑니다. 인증서 이름이 `ureka.magonjal.com`입니다. `magonjal.com`·`www.magonjal.com`은 이 작업으로 생긴 레코드가 없습니다.
- [ ] `https://ureka.magonjal.com/api/recommend/…`처럼 내부 경로를 부르면 recommend에 닿지 않습니다(화면 HTML이 나옴).
- [ ] 시험자 목록에 없는 IP(다른 회선)에서는 ALB에 연결되지 않습니다(시간 초과).
- [ ] 비용 알림(예산)이 켜져 있고, 끄는 날짜·담당자를 정했습니다.

## 시험 방법

응답 본문(토큰·쿠키)은 저장하거나 공유하지 않습니다.

### 시험 1: 비회원 발급 제한 (#81)

관리자 목록에 없는 시험 IP에서 실행합니다. 시험 중에는 그 IP의 정상 발급도 막힙니다.

```sh
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST https://ureka.magonjal.com/api/auth/v1/guest-tokens \
    -H 'Content-Type: application/json' -d '{}')
  echo "$(date +%T) $i $code"; sleep 2
done
```

- auth#44가 들어가면 봇 확인 값이 없어 4xx가 나올 수 있습니다. WAF는 앱 응답과 상관없이 요청 수를 셉니다. 429가 나오는 시점과 WAF 지표 `rate-limit-guest-tokens`의 차단 수를 함께 기록합니다(앱의 4xx와 구별).
- 기록할 것: 처음 429가 나온 회차와 시각, 마지막 시도 뒤 다시 429가 아닌 응답으로 돌아온 시각.
- 시험 뒤 그 IP에서 생긴 비회원 actor 수를 확인합니다(DB 누적, 위협 모델 T1).

### 시험 2: 관리자 경로 IP 제한 (#64)

```sh
# 관리자 목록에 없는 시험 IP에서
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/admin                    # 403
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/api/admin/v1/incidents   # 403 (경로는 ops 기준으로 바꿔서)
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/api/admin/v1/public-notice  # 200 (예외)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://ureka.magonjal.com/api/admin/v1/public-notice  # 403 (GET만 예외)
# 관리자 IP에서: /admin 화면이 열리고, ADMIN 토큰 없이 부르는 관리자 API는 ops가 401/403
```

### 시험 3: 경로 정규화

`curl --path-as-is`로 경로를 그대로 보냅니다. 모두 관리자 목록에 없는 시험 IP에서 실행합니다.

```sh
for p in '/api//admin/v1/incidents' '/api/./admin/v1/incidents' '/api/x/../admin/v1/incidents' \
         '/api/%2e%2e/admin/v1/incidents' '/api/admin%2fv1/incidents' '/api/admin;x/v1/incidents' \
         '/api/admin/v1/public-notice/../incidents' '/api/auth/v1//guest-tokens'; do
  echo "$p $(curl --path-as-is -s -o /dev/null -w '%{http_code}' "https://ureka.magonjal.com$p")"   # 모두 400
done
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/api/%61dmin/v1/incidents       # 403 (디코딩 뒤 관리자)
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/API/ADMIN/v1/incidents         # 403 (소문자 뒤 관리자)
curl -s -o /dev/null -w '%{http_code}\n' https://ureka.magonjal.com/API/ADMIN/V1/PUBLIC-NOTICE     # 403 (예외는 원래 경로 그대로만)
```

- 대문자·인코딩 경로는 ALB 경로 규칙(대소문자 구분)상 ops로 가지 않고 화면(nginx)으로 갑니다. WAF가 그보다 먼저 막는지 확인하는 시험입니다.
- 발급 경로도 `POST /api/auth/v1/%67uest-tokens`를 시험 1처럼 반복해 같은 카운터로 429가 나는지 봅니다.

## 끄기 순서 (하나로 고정)

2단계(DNS)가 켜진 상태 그대로 진행합니다. tfvars는 바꾸지 않습니다. [eks.md 끄기](eks.md) 앞에 다음을 넣습니다.

1. 참가자에게 종료를 안내합니다.
2. Argo CD에서 `ureka-prod-public-ingress` Application을 지웁니다(리소스 함께 삭제). 컨트롤러가 ALB·대상 그룹·백엔드 SG와 노드 SG의 백엔드 규칙을 지울 때까지 **컨트롤러는 살려 둡니다.**
3. `elbv2.k8s.aws/cluster=ureka-eks` 태그 ALB가 0개인지 확인합니다. 운영 도구의 destroy plan도 남아 있으면 멈춥니다.
4. 기존 eks.md 끄기 순서(앱 정리 → data SG 참조 제거 → 운영 도구 destroy plan·apply)를 따릅니다.
   - ALB가 없어도 DNS 조회(`aws_lbs`)가 실패하지 않습니다. destroy가 별칭 레코드·인증서·검증 레코드·WAF·IP 목록·입구 SG·prefix list·컨트롤러 역할을 같이 지웁니다.
   - DNS 레코드만 먼저 지우는 일반 plan은 운영 도구가 거부하므로 쓰지 않습니다.
5. 잔존 확인: ALB 0, WAF Web ACL `ureka-eks-public` 없음, SG `ureka-eks-alb-public` 없음, 인증서 없음(검증 CNAME도 삭제), Route 53 영역은 남음(Terraform 밖).

## 알려진 한계·후속

- CloudFront·Shield·AWS 관리형 규칙(Common Rule Set)은 없습니다. 관리형 규칙은 채팅 글이 잘못 막힐 수 있어서 시험 뒤에 다시 봅니다.
- 시험자·관리자 목록은 IPv4 /32만 받습니다. IP가 바뀌면 tfvars를 고치고 apply합니다.
- `open`에서 `testers`로 되돌리는 것(공개 규칙 삭제)은 운영 도구 일반 plan이 거부합니다. 급하게 닫아야 하면 공개 Ingress Application을 지워 ALB를 없애는 것이 가장 빠릅니다.
- Pod readiness gate(배포 중 ALB 대상 준비 확인)는 prod 네임스페이스 라벨이 필요합니다. 네임스페이스는 #62 담당이라 후속으로 둡니다. 지금은 롤링 배포 때 짧은 502가 날 수 있습니다.
- Argo CD 프로젝트는 지금 `default`입니다. #43 AppProject가 병합되면 옮깁니다.
  - 공개 Ingress: `ureka-eks-prod`에 Ingress(·NetworkPolicy)를 허용 목록에 더함
  - 컨트롤러: 플랫폼용 프로젝트에 eks-charts 저장소·kube-system·클러스터 범위 종류(CRD 7개, IngressClass, IngressClassParams, 웹훅 설정, ClusterRole/Binding)를 허용
- 컨트롤러 차트를 올릴 때는 차트 버전·digest, `policies/` 정책 파일, 정책 sha256 시험, 이 문서를 같이 올립니다.

## 로컬 검증 (AWS·클러스터 불필요)

```sh
(cd infra/environments/eks && terraform init -backend=false && terraform test)   # mock provider
bash scripts/test-eks-public.sh          # 공개 Ingress 렌더링·값 대조 + 컨트롤러 차트 실제 렌더 → CRD 스키마 검사(차트 내려받음)
python3 -m unittest discover -s tests/eks # 등록·확인 스크립트, destroy ALB 검사, ARN 임시 파일 입력
bash scripts/check-forbidden-files.sh
```

## 시험 기록

| 항목 | 날짜 | 결과 | 비고 |
|---|---|---|---|
| 1단계 apply(인증서 ISSUED까지) | 미실행 | | |
| ALB 생성(Ingress Sync → active) | 미실행 | | |
| verify(SG·WAF 연결) | 미실행 | | |
| 시험자 밖 IP 접속 불가 | 미실행 | | |
| 발급 제한: 처음 429 회차·풀린 시간 | 미실행 | | |
| 관리자 경로 403·공지 200 | 미실행 | | |
| 경로 정규화 400/403 | 미실행 | | |
| 내부 흐름(채팅→추천→작품) | 미실행 | | |
| SES 실제 메일 수신 시간 | 미실행 | | |
| open 전환 | 미실행 | | |
| Ingress 삭제 → ALB 0 → destroy | 미실행 | | |

참고: [ALB 컨트롤러 주석](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/), [IngressClassParams](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/ingress_class/), [인증서 찾기](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/cert_discovery/), [ALB 규칙 조건](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-condition-types.html), [WAF 요청 수 제한 설정](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-high-level-settings.html), [WAF 요금](https://aws.amazon.com/waf/pricing/), [ELB 요금](https://aws.amazon.com/elasticloadbalancing/pricing/), [VPC 요금(공인 IPv4)](https://aws.amazon.com/vpc/pricing/).
