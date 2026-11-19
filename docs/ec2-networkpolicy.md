# EC2 dev 들어오는 연결 정책 (#39·#40)

dev 네임스페이스의 Pod는 **기본으로 아무 연결도 받지 않고**(#39), 아래 표에 있는 연결만 받습니다(#40).
서비스 간 보안은 NetworkPolicy + 내부 토큰 두 겹으로 합니다(Istio는 EKS에서 나중에 검토, 붙여도 NetworkPolicy는 같이 씁니다).

| 파일 | 내용 |
|---|---|
| `environments/ec2/dev/networkpolicy/default-deny-ingress.yaml` | #39 기본 거부(모든 Pod, ingress만) |
| `environments/ec2/dev/networkpolicy/allow-ingress.yaml` | #40 받는 쪽 Pod별 허용 8개 |
| `argocd/ec2/apps/templates/networkpolicy.yaml` | Argo CD Application `ureka-dev-networkpolicy-ec2-dev`(wave -1, 자동 동기화·selfHeal, finalizer) |
| `charts/ureka-observability/templates/networkpolicy.yaml` | 지표 포트 허용(관측을 켤 때만 생김): Prometheus → auth·content 9091, chat 8080 |
| `tests/networkpolicy/expected.json` | 허용 표(시험의 기준). 여기 없는 조합은 모두 막혀야 합니다 |
| `scripts/test-dev-networkpolicy.sh` | 정적 시험(CI) |
| `scripts/netpol/probe.sh`, `scripts/netpol/flow.py` | 실제 차단 시험, 사용자 흐름 시험(kind·EC2 공통) |

기본 거부와 허용은 **항상 같이** 배포합니다. 기본 거부만 들어가면 모든 서비스가 끊깁니다(정적 시험이 이 경우를 실패로 잡습니다).

## 연결 표

코드·차트·values에서 확인한 dev의 실제 연결입니다. "정책" 열이 이 PR에서 하는 일입니다.

| # | 보내는 쪽 → 받는 쪽:포트 | 용도 | 근거 | 정책 |
|---|---|---|---|---|
| 1 | Traefik(kube-system) → frontend:8080 | 사용자 입구(SSM 터널 → Traefik → 프론트) | `environments/ec2/dev/ureka-frontend.yaml` ingress `traefik` | 허용 `allow-frontend-from-traefik`. **EC2 확인 필요**: Traefik Pod 이름표 `app.kubernetes.io/name=traefik`, hostNetwork 아님 |
| 2 | frontend → auth·chat·content·ops:8080 | nginx가 `/api/{auth,chat,content,admin}/`을 넘김 | `environments/base/ureka-frontend.yaml` `*_UPSTREAM`, ureka-frontend `nginx/default.conf.template` | 허용 |
| 3 | auth → chat·content:8080 | 탈퇴 정리 `PUT /internal/v1/subject-cleanups` | base `ureka-auth.yaml` `CHAT_SERVICE_URL`·`CONTENT_SERVICE_URL`, ureka-auth `WithdrawalWorker.kt` | 허용 |
| 4 | auth → ops:8080 | 탈퇴 정리(ops) | ureka-auth `OPS_SERVICE_URL`(비어 있으면 ops를 대상에서 뺌). values에 없음 | **허용 안 함**(지금 호출 없음). 켤 때 `allow-ops`에 auth 추가 |
| 5 | chat api·worker → content:8080 | 선택지 `/api/content/v1/catalogs`, 작품 조회 | base `ureka-chat*.yaml` `CONTENT_BASE_URL`, ureka-chat `adapters/providers.py`, worker는 `services/rag_result.py` 경유 | 허용 |
| 6 | chat api·worker → recommend:8000 | `POST /internal/v1/recommendations` | `RECOMMEND_BASE_URL` | 허용 |
| 7 | recommend → content:8080 | 실제 모드의 `GET /api/content/v1/catalogs`(#68) | #40 댓글, ureka-recommend `app/catalog.py`. 지금 모의 모드라 호출 없음 | 허용(미리 엶) |
| 8 | auth·content → Redis:6379 | 리프레시 토큰, 토큰 폐기 확인 | base `REDIS_HOST`, ureka-common `TokenRevocationChecker` | 허용. chat·ops는 Redis를 쓰지 않음 |
| 9 | auth → Mailpit:1025 | 가입 인증 메일(dev) | base `ureka-auth.yaml` `MAIL_HOST` | 허용. 메일 화면 8025는 Pod 안 127.0.0.1 전용(port-forward) |
| 10 | 각 서비스·Job → `postgres`(RDS):5432 | DB | `environments/ec2/dev/data` Service `postgres` = ExternalName(클러스터 밖) | 영향 없음(나가는 연결, 막지 않음) |
| 11 | chat·recommend·ingest → Gemini 443, ingest → RDS | AI·적재 | values, `environments/ec2/dev/ingest/networkpolicy.yaml` | 영향 없음. ingest는 자기 정책으로 egress까지 막고 ingress `[]` → 기본 거부와 같은 방향, 충돌 없음 |
| 12 | 모든 Pod → CoreDNS(kube-system):53 | 이름 풀기 | — | 영향 없음(나가는 연결) |
| 13 | Prometheus(observability) → auth·content:9091, chat:8080 | 지표 | `charts/ureka-observability` (`appMetrics.enabled`·`chatEnabled`, 지금 둘 다 false) | 관측 차트가 켤 때만 Prometheus 한 주체로 엶. 이 PR에서 dev 전체에 8080을 열던 규칙을 뺌(아래) |
| 14 | Prometheus → kubelet cAdvisor, kube-state-metrics | 노드·클러스터 지표 | `files/prometheus.yml` | 영향 없음(dev Pod가 아님) |
| 15 | Argo CD → API 서버 | 동기화, PreSync 마이그레이션 Job | — | 영향 없음(dev Pod로 들어오는 연결이 없음. Job은 나가는 연결만) |
| 16 | kubelet(노드) → Pod 헬스 체크 | startup·liveness·readiness | 차트 probes | kind: 정책 적용 뒤 모든 Pod Ready 유지. **EC2 확인 필요**(k3s kube-router는 노드 → Pod를 허용) |
| 17 | `kubectl port-forward`·`exec`·`logs` | Mailpit 화면, Argo CD, 운영 확인 | — | 영향 없음(kubelet 경로). kind에서 port-forward로 흐름 시험 통과 |
| 18 | rds-bootstrap Job → RDS | DB 계정 | `scripts/ec2/rds-bootstrap.sh` | 영향 없음(나가는 연결) |

나가는 연결(egress) 제한은 이번 범위가 아닙니다. 하려면 DNS·RDS 사설 대역·Gemini 443·서비스 간 호출을 Pod별로 열어야 해서 따로 제안합니다(ingest 정책이 그 모양의 예).

### 관측 차트에서 바꾼 것

전에는 `obs-auth-metrics`·`obs-content-metrics`가 auth·content의 8080을 **dev 네임스페이스 전체**에 열었습니다(그때는 dev에 다른 정책이 없어 업무 연결을 지키려던 것). 정책은 합집합이라 이 규칙이 남으면 #40 허용 표가 무너집니다(예: recommend → auth 8080이 열림). 이제 업무 8080은 dev 정책이 서비스별로 열고, 관측 정책은 지표 포트만 Prometheus에 엽니다. chat 지표(`chatEnabled`)는 업무 포트 8080의 `/internal/v1/metrics`를 수집 전용 토큰으로 긁으므로 Prometheus → chat 8080 정책을 같이 만듭니다.

그래서 **관측을 켤 때(`appMetrics.enabled: true`) dev 정책이 먼저 실제로 들어가 있어야 합니다.** dev 정책은 자동 동기화, 관측 앱은 수동 Sync지만 이것만으로 순서가 보장되지는 않습니다(dev 정책 Application이 만들어지기만 하고 Sync가 실패한 상태에서 관측을 먼저 Sync할 수 있음). 관측 앱을 Sync하기 전에 아래를 모두 확인합니다.

```bash
sudo k3s kubectl -n argocd get application ureka-dev-networkpolicy-ec2-dev   # Synced / Healthy
sudo k3s kubectl -n dev get networkpolicy dev-default-deny-ingress allow-auth allow-content allow-chat   # 모두 있음
sudo bash scripts/netpol/probe.sh                                              # 표와 다름 0개
BASE_URL=http://127.0.0.1 MAILPIT_URL=http://127.0.0.1:8025 python3 scripts/netpol/flow.py   # 모두 PASS
```

관측을 켠 상태에서는 dev 정책을 되돌리는 방법이 달라집니다(아래 "되돌리기").

### 이름표로 막는 것의 한계

NetworkPolicy는 Pod 이름표(`app.kubernetes.io/name`)로 보내는 쪽을 구분합니다. 인증 주체를 증명하는 것이 아닙니다. dev에 Pod를 만들 수 있는 사람은 이름표를 흉내 낼 수 있고, 같은 네임스페이스의 Secret을 Pod에 붙여 내부 토큰도 얻을 수 있습니다(PSA restricted는 권한 상승·호스트 접근을 막지만 정상적인 Secret 사용은 막지 않음). 그래서 내부 토큰도 그런 사람까지 막지는 못합니다. 전제는 **dev에서 Pod 생성·exec·Secret 읽기 권한을 믿을 수 있는 운영자(CN)로만 한정하는 RBAC**입니다. NetworkPolicy와 내부 토큰은 그 위에서 앱 하나가 뚫렸을 때 옆으로 번지는 것을 줄이는 겹입니다. 다른 네임스페이스는 네임스페이스 AND Pod 이름표를 한 항목에 같이 써서, 다른 네임스페이스에서 이름표만 흉내 낸 Pod는 막힙니다(시험 표의 `default/traefik-흉내`·`default/obs-prometheus-흉내`).

## 시험

### 1. 정적 시험 (CI, 클러스터 없음)

```bash
bash scripts/test-dev-networkpolicy.sh
```

- dev 정책 + ingest 정책 + 관측 정책(꺼짐/켬 두 경우)을 합쳐 계산하고, 보내는 쪽 19 × 받는 쪽·포트 14 = 266개 조합이 `expected.json`과 정확히 같은지 봅니다.
- 형식: dev 네임스페이스, Ingress만, 기본 거부 정확히 하나, kustomization에 두 파일, 넓은 규칙(빈 from·빈 ports·ipBlock) 없음.
- root 앱이 Application을 만들고 경로·wave -1·finalizer·selfHeal이 맞는지.
- 시험이 헛돌지 않는지: 기본 거부만(=#39만 병합), dev 전체 허용이 섞임, 기본 거부 빠짐 세 경우가 **실패**해야 통과입니다.
- 실제 CNI 동작은 대신하지 못합니다. 아래 2·3번을 봅니다.

### 2. kind 시험 (로컬, 2026-11-19 결과)

```bash
kubectl --context kind-ureka apply -k environments/ec2/dev/networkpolicy
kubectl --context kind-ureka apply -f tests/networkpolicy/kind-postgres.yaml   # kind는 DB가 클러스터 안 Pod라서 시험 전용
bash scripts/netpol/probe.sh --context kind-ureka
kubectl --context kind-ureka -n dev port-forward svc/ureka-frontend 18080:80 &
kubectl --context kind-ureka -n dev port-forward deploy/mailpit 18025:8025 &
BASE_URL=http://127.0.0.1:18080 MAILPIT_URL=http://127.0.0.1:18025 python3 scripts/netpol/flow.py
# 끝나면 지운다
kubectl --context kind-ureka -n dev delete networkpolicy -l app.kubernetes.io/component=networkpolicy
```

`probe.sh`는 받는 쪽 Pod 없음·시험 Pod 실행 실패·결과 행 빠짐/중복/모르는 행·표와 다름 중 하나라도 있으면 실패합니다. 대상 포트마다 허용 출발지가 하나 이상 있어야 해서, 서비스가 죽어 생긴 '차단'을 성공으로 읽지 않습니다. `expected.json`의 보내는 쪽마다 같은 이름표를 단 시험 Pod를 그 네임스페이스에 띄우고(PSA restricted를 지킴), dev의 실제 Pod IP:포트로 TCP 연결을 시도해 표와 비교합니다. 리스너가 있는 포트만 봅니다(나머지는 정적 시험).

| 시점 | 결과 |
|---|---|
| 정책 전 | 152개 조합 모두 연결됨(막혀야 할 137개가 열려 있음) |
| 정책 후 | 152개 조합 표와 다름 0개(허용 15개 연결, 나머지 137개 차단) |
| 흐름(정책 후) | 선택지 → 이메일 인증(Mailpit) → 가입 → 로그인 → 페르소나 → 장르 추천 201 → 관리 API 403(도달) 모두 PASS |
| Pod | auth·chat·content·ops·recommend·frontend·redis·mailpit·postgres Ready 유지(헬스 체크 영향 없음) |

kind는 Traefik·Prometheus가 없어 그 자리는 같은 이름표의 시험 Pod로 확인했습니다. 실제 Traefik·Prometheus는 EC2에서 봅니다.

### 3. EC2 시험 (EC2를 켤 때 같이)

EC2 셸(SSM)에서 저장소(`~/ureka-gitops`)를 받아 둔 상태를 기준으로 합니다. k3s는 root로 `kubectl`이 됩니다.

1. 사전 확인 (병합 전)
   ```bash
   cd ~/ureka-gitops && git pull
   sudo k3s kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o wide        # 1개 이상
   sudo k3s kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].spec.hostNetwork}'; echo   # 비어 있거나 false
   sudo k3s kubectl get networkpolicy -A                                                     # dev에 ingest·obs 말고 없음
   ```
   Traefik 이름표가 다르면 병합하지 말고 `allow-frontend-from-traefik`를 먼저 고칩니다.
2. 기준선 흐름 (정책 전)
   ```bash
   sudo k3s kubectl -n dev port-forward deploy/mailpit 8025:8025 >/dev/null 2>&1 &
   BASE_URL=http://127.0.0.1 MAILPIT_URL=http://127.0.0.1:8025 python3 scripts/netpol/flow.py
   ```
   `BASE_URL=http://127.0.0.1`은 노드 80번(Traefik)이라 Traefik → 프론트 정책까지 같이 지나갑니다.
3. PR 병합 → 동기화 확인 (3분 안쪽, 급하면 refresh)
   ```bash
   sudo k3s kubectl -n argocd annotate application ureka-ec2-dev-root argocd.argoproj.io/refresh=normal --overwrite
   sudo k3s kubectl -n argocd get application ureka-dev-networkpolicy-ec2-dev   # Synced / Healthy
   sudo k3s kubectl -n dev get networkpolicy                                    # dev-default-deny-ingress + allow-* 8개 (+ ingest)
   ```
4. 차단·허용 시험과 흐름
   ```bash
   git pull && sudo bash scripts/netpol/probe.sh          # 표와 다름 0개
   BASE_URL=http://127.0.0.1 MAILPIT_URL=http://127.0.0.1:8025 python3 scripts/netpol/flow.py   # 모두 PASS
   sudo k3s kubectl -n dev get pods                       # 모두 Ready, 재시작 수 늘지 않음
   sudo k3s kubectl -n argocd get applications            # 모두 Synced/Healthy
   ```
5. 관측을 켠 뒤(별도 순서, `docs/ec2-observability.md`)에는 지표 포트까지 봅니다.
   ```bash
   sudo PROBE_TARGETS="ureka-frontend:8080 ureka-auth:8080 ureka-chat:8080 ureka-content:8080 ureka-ops:8080 ureka-recommend:8000 redis:6379 mailpit:1025 ureka-auth:9091 ureka-content:9091" \
     bash scripts/netpol/probe.sh --scenario "관측 켬(appMetrics.enabled·chatEnabled) 때 추가"
   ```

결과 표(`probe.sh` 출력)는 #41(막혀야 할 연결 시험 기록)에 그대로 붙입니다.

## 되돌리기

관측 지표(`appMetrics.enabled`)를 켰는지에 따라 다릅니다. 켠 상태에서는 관측 정책(`obs-auth-metrics` 등)이 auth·content(·chat)를 지표 포트만 받게 격리하므로, dev 정책만 되돌리면 그 서비스의 업무 8080이 계속 닫힙니다(관측 앱은 수동 Sync라 같이 바뀌지 않음).

| 상황 | 방법 | 걸리는 시간 |
|---|---|---|
| 급함(서비스가 끊김) | 아래 "전부 허용" 임시 정책을 손으로 넣는다. 합집합이라 바로 다 열린다. Argo CD는 자기가 만들지 않은 이 정책을 지우지 않는다. **지표 포트(9091)와 ingest Pod 수신까지 dev 전체가 열리므로** 원인을 고치면 바로 지운다 | 몇 초 |
| 보통, 관측 꺼짐 | 이 PR을 되돌리는 PR → 병합. root 앱이 Application을 지우고 finalizer가 dev 정책도 지운다 | 병합 + 3분 안쪽 |
| 보통, 관측 켬 | ① 임시 전부 허용을 넣는다 ② 관측도 되돌린다: `appMetrics.enabled: false`(또는 관측 정책을 이 PR 이전 형태로) PR을 병합하고 관측 앱을 **Prune을 켜고** 수동 Sync(관측 앱은 자동 prune이 없어 그냥 Sync하면 옛 정책이 남는다) → `sudo k3s kubectl -n dev get networkpolicy`에 `obs-*-metrics`가 없거나 이전 형태인지 확인 ③ 이 PR을 되돌리는 PR 병합 → dev 정책 사라짐 확인 ④ `flow.py` 모두 PASS 확인 ⑤ 임시 전부 허용 삭제 → `flow.py` 다시 PASS | 병합 2번 + 확인 |
| 한 연결만 빠짐 | `allow-ingress.yaml`과 `expected.json`에 그 연결을 더하는 PR | 병합 + 3분 안쪽 |

```bash
# 임시 전부 허용. 원인을 고친 뒤 반드시 지운다.
cat <<'EOF' | sudo k3s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: temp-allow-all-ingress, namespace: dev}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{}]
EOF
sudo k3s kubectl -n dev delete networkpolicy temp-allow-all-ingress   # 고친 뒤
```

dev 정책을 `kubectl delete`로 지우거나 고치면 selfHeal이 Git 상태로 바로 되돌립니다. 자식 Application의 자동 동기화를 손으로 꺼도 root 앱 selfHeal이 다시 켭니다. 그래서 급할 때는 지우지 말고 위처럼 더합니다.
