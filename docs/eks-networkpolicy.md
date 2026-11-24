# EKS dev·prod NetworkPolicy와 실제 차단 시험 (#49)

이 문서는 **구현·정적 검증 결과와 실제 차단 시험을 구분**한다. 실제 EKS 시험은 아직 실행하지 않았다. 아래 클러스터 명령은 CN 담당이 승인된 가동 시간에만 실행한다. prod는 수동 Sync다.

## 정책과 앱 연결

- 공통 Helm chart: `charts/ureka-networkpolicy`, 환경 값: `environments/eks/{dev,prod}/networkpolicy/values.yaml`.
- 모든 Pod의 ingress 기본 거부 + 같은 namespace 내부 호출 14개. EC2의 15개에서 EKS에 없는 Traefik→frontend를 뺀 목록이다. dev 화면은 기존 승인된 port-forward 경로를 쓴다.
- frontend→auth/chat/content/ops, auth→chat/content/Redis/Mailpit, chat api·worker→content/recommend, recommend→content, content→Redis만 허용. dev↔prod는 같은 이름표여도 차단한다. auth→ops는 현재 OPS_SERVICE_URL이 비어 있어 열지 않는다.
- recommend 8000은 chat api·worker만 받는다. worker·migration·미지정 Pod·Mailpit UI 8025는 inbound를 열지 않는다.
- ESO·Argo CD·ALB 컨트롤러는 Kubernetes API를 조작하므로 업무 Pod로 오는 허용 규칙이 필요하지 않다. 해당 namespace·같은 이름표 흉내도 기대 표에서 차단한다. webhook 등 플랫폼 자체 통신은 이 업무 namespace 정책 범위 밖이다.
- monitoring의 `app.kubernetes.io/name=obs-prometheus`만 선택적으로 auth/content 9091, chat 8080에 접근한다. namespace AND Pod 한 peer로 제한한다. 관측이 없을 때는 두 metrics 옵션 모두 false. 관측 담당의 실제 Prometheus 이름표와 맞춰야 하며, 관측 chart가 별도 허용을 만들면 **합집합 전체**를 다시 검사한다.
- **egress 기본 거부는 추가하지 않는다.** DNS·RDS·Gemini·SQS·SES는 이번 작업으로 막히지 않는다. Secret·내부 토큰·RBAC·PSA·SG는 계속 필요하다. 노드/hostNetwork/port-forward 경로의 예외를 Pod 간 차단의 증거로 사용하지 않는다.

#43 root chart에 `ureka-eks-networkpolicy-dev/prod` 앱을 추가했다. wave -1(네임스페이스 -2 이후), env 전용 프로젝트·목적지, dev 자동·prod 수동이다. 프로젝트 허용 목록에는 NetworkPolicy 종류만 추가했다. default deny와 허용 규칙은 **같은 앱**에서 배포한다. 서비스와 정책은 서로 다른 앱이라 Sync wave만으로 실제 서비스/정책 Ready와 CNI 적용 순서가 원자적으로 보장되지는 않는다. 첫 설치는 서비스 공개 전에 정책 적용·PolicyEndpoint·negative probe를 확인한다.

#43 파일 변경은 새 template 1개, values 설정, 프로젝트 종류 허용뿐이다. #64도 projects.yaml에 Ingress를 추가하므로 두 줄을 모두 보존해 충돌을 해결해야 한다. 정책 앱 삭제가 자동으로 보호를 제거하지 않도록 finalizer를 넣지 않았다. 자원 제거는 CN 담당의 별도 검토가 필요하다.

## ALB(target-type ip) 허용 판단

prod 공개 경로는 #64가 ALB에서 frontend·auth·chat·content·ops의 **Pod 8080**으로 직접 연결한다. ALB 컨트롤러 Pod는 데이터 트래픽 출발지가 아니므로 그 이름표를 허용하지 않는다.

ALB 연결과 health check 출발지는 ALB가 놓인 서브넷 IP 범위로 한정한다. 승인된 **ALB public-subnet CIDR 목록**을 `ipBlock`으로 5개 대상의 TCP 8080에만 적용한다. recommend·Redis·Mailpit·지표 포트는 ALB에 열지 않는다. VPC 전체 CIDR이나 0.0.0.0/0, 노드 전체를 편의상 열지 않는다. 실제 CIDR은 Git에 넣지 않고 Terraform network output에서 읽는다.

CIDR은 ALB 신원 인증이 아니다. 같은 서브넷의 다른 자원도 범위에 포함될 수 있으므로 #64의 ALB 프런트엔드/백엔드 SG·TLS·WAF·API 인증을 유지한다. 실제 패킷의 출발지/NAT 처리와 허용·차단을 EKS에서 확인해야 하며, 정적 계산만으로 ALB 허용 성공이라고 쓰지 않는다. 향후 ALB 서브넷·CNI·target-type이 바뀌면 다시 검증한다.

안전한 초기 상태:

- prod 환경 values 자체는 ALB 활성화를 요구하며 CIDR이 없으면 chart 렌더링이 실패한다.
- root chart는 `networkPolicy.alb.enabled=false`를 명시적으로 덮어써 **#64 공개 전에는 ALB 경로를 닫는다**. root 등록만으로 외부 길이 열리지 않는다.
- #64 배포 전에 CN 담당이 CIDR을 주입하고 prod 정책 앱을 수동 Sync해야 한다. 생략하면 ALB health check와 접근이 실패하므로 공개를 진행하지 않는다.

다음은 **미실행 운영 절차**다. 로컬에 초기화된 network Terraform 폴더에서 ALB에 실제 할당할 public subnet 목록을 담당자가 먼저 대조한다. 아래 값은 출력/화면 공유/커밋하지 않는다.

```bash
set -o pipefail
terraform -chdir=infra/environments/network output -json subnet_cidrs \
  | jq '[.public[]]' \
  | python3 scripts/netpol/alb-root-patch.py \
  | kubectl --context "$EKS_CONTEXT" -n argocd patch application ureka-eks-root \
      --type=json --patch-file=/dev/stdin
```

패치 도구는 **표준 입력 검증·JSON patch 생성만** 하며 클러스터 명령을 실행하지 않는다. 기존 ecrRegistry 파라미터를 읽거나 덮어쓰지 않는다. 이 절차는 최초 주입용이다. 반복 실행 시 같은 이름의 Helm 파라미터가 중복되므로 기존 `networkPolicy.alb.*` 파라미터를 확인하고 승인된 전체 목록으로 정리한 뒤 실행한다. root 앱 재등록/재생성 시 이 주입도 다시 해야 한다(실값은 비공개 운영 기록만). 값이 불확실하면 공개를 열지 않는다. 실제 선택된 ALB 서브넷만 허용하며 위 출력의 모든 public subnet을 무조건 신뢰하지 않는다.

이후 Argo CD에서 prod 정책 앱 Diff→수동 Sync→health check·공개 요청 시험을 한다. metrics 활성화는 관측과 함께 root `networkPolicy.metrics.enabled/chatEnabled`와 앱 지표 설정을 맞추는 별도 변경이다.

## 기대 표와 정적 시험

`tests/networkpolicy/eks-dev.json`, `eks-prod.json`은 chart 렌더링에서 역생성하지 않은 독립 허용 표다. IP 항목은 **합성 시험 값**이며 운영 CIDR이 아니다. external/alb-subnet 행은 정적 계산만 하며 실제 ALB를 Pod로 흉내 내지 않는다. 다른 namespace·플랫폼·미지정 Pod·외부 IP는 허용 표에 없으면 차단이다.

| 환경·시나리오 | 정적 조합 | 허용 | 의미 |
|---|---:|---:|---|
| dev baseline | 390 | 14 | 내부 호출 |
| dev metrics | 390 | 17 | 내부 + 지표 3개 |
| prod baseline | 390 | 14 | ALB를 닫은 초기 상태 |
| prod metrics | 390 | 17 | ALB 닫힘 + 지표 |
| prod alb | 390 | 19 | 내부 + ALB 5개 |
| prod alb-metrics | 390 | 22 | 내부 + ALB + 지표 |

```bash
bash scripts/test-eks-networkpolicy.sh
bash scripts/test-dev-networkpolicy.sh
bash scripts/check-charts.sh
```

정적 시험은 누락된 default deny·허용만 있는 정책·과도한 허용·namespace/Pod OR 오류·잘못된 CIDR·다른 namespace 접근·ipBlock except·prod 수동 Sync를 확인한다. 기존 EC2 계산기는 ipBlock 지원을 기본으로 열지 않고 EKS 표에서만 opt-in한다. 실제 차단 검증을 대신하지 않는다.

## EKS 실제 시험 (CN 담당, 클러스터 변경 있음)

1. #42 EKS VPC CNI `enableNetworkPolicy=true`, EC2 Linux 노드와 network-policy-agent 상태·버전을 기록한다. AWS 문서상 Deployment 외 Pod의 정책 적용에는 제약이 있으므로 **auth Rollout 및 migration Job을 자동으로 보호된다고 단정하지 않는다**. 해당 실제 Pod의 PolicyEndpoint와 노드 agent 적용을 먼저 확인한다. 미지원/누락이면 시험·공개를 중단하고 플랫폼 담당과 CNI/워크로드 대안을 정한다.
2. 정책 앱(dev 자동, prod 수동)이 Synced인지 확인하고, 실제 NetworkPolicy의 합집합이 의도와 같은지 확인한다. PolicyEndpoint 수렴 전에 트래픽을 열지 않는다(standard mode의 초기 default allow 주의).
3. 서비스가 Ready인지, 각 대상의 실제 포트가 열렸는지 확인한다. 지표가 꺼져 있으면 9091은 시험 대상에 넣지 않는다. 실제로 존재하는 허용 리스너를 한 번도 확인하지 못한 대상을 '차단 성공'으로 기록하지 않는다.
4. 다음 명령은 EKS에서 **시험용 Deployment를 생성·삭제**한다. 명시적 context/namespace 필수이며 기존 EC2/kind 명령은 그대로 유지된다.

```bash
bash scripts/netpol/probe.sh --context "$EKS_CONTEXT" --namespace dev --scenario baseline
bash scripts/netpol/probe.sh --context "$EKS_CONTEXT" --namespace prod --scenario baseline
```

EKS 도구는 namespace별 기대 표를 읽는다. 한 출발지씩 실행해 Quota 소비를 줄이고, 시험용 Pod는 의도적으로 Ready가 되지 않게 하여 운영 Service의 트래픽을 받지 않는다. 기존 namespace/Deployment/정책은 수정하지 않는다. 없는 시험용 플랫폼 namespace는 restricted 라벨로 생성하고 이 실행이 만든 것만 정리한다. Pod·정책 IP·Secret·레지스트리 주소를 결과에 출력하지 않는다. `publishNotReadyAddresses` Service에 시험 Pod가 들어갈 수 있으면 중단한다.

모든 Ready 대상 replica를 확인하고 실제 PolicyEndpoint의 Pod 이름·namespace·IP·Ingress isolation 대응이 없으면 시험을 중단한다. 특정 replica가 누락되거나 결과가 다르면 실패한다. 소스 수×선택한 대상 수 결과가 완전해야 하며 exec 실패·누락·중복은 성공으로 처리하지 않는다. 기본 대상은 auth/chat/content/ops/recommend/Redis/Mailpit 7개다. external 2개 행은 제외하므로 기본 **24 sources × 7 = 168 조합/환경**이다. frontend는 baseline에서 양성 대조군이 없어 Pod probe의 기본 대상에서 제외하고 ALB 시험에서 검증한다.

metrics가 실제 활성화된 경우에만 시나리오 `metrics`와 `PROBE_TARGETS`로 지표 포트를 추가한다. prod ALB 활성화 후에는 `alb` 또는 `alb-metrics`를 쓴다. external 행은 이때도 실제 Pod TCP probe에서 제외된다.

```bash
PROBE_TARGETS='ureka-auth:8080 ureka-chat:8080 ureka-content:8080 ureka-ops:8080 ureka-recommend:8000 redis:6379 mailpit:1025 ureka-auth:9091 ureka-content:9091' \
  bash scripts/netpol/probe.sh --context "$EKS_CONTEXT" --namespace prod --scenario alb-metrics
```

외부 ALB 시험은 별도로 수행한다.

- 승인된 사용자 경로에서 TLS와 frontend·auth/chat/content/ops의 허용 API 호출 확인. `/healthz` 상태 하나만으로 업무 경로 성공으로 적지 않는다. ALB target group 5개 대상 health check도 확인.
- recommend는 외부 Ingress가 없어야 한다. 외부에서 직접 접근이 안 되는지, dev는 공개되지 않는지 확인.
- 허용되지 않은 namespace Pod→업무 Pod 차단과 ALB→업무 Pod 허용을 각각 기록한다. ALB 허용은 별도 health check·접속·노드 agent evidence로 확인한다. 임의 Pod의 label만 바꿔 ALB 출발지라고 주장하지 않는다.
- 실제 Service ClusterIP 경로도 업무 API로 확인한다(Pod IP probe는 DNS/Service DNAT/HTTP 인증을 검증하지 않음). RDS·Gemini/SES/SQS는 별도 실제 기능 시험으로 확인한다.

### 기록 칸 (실측 전: 전부 미실행)

| 항목 | dev | prod |
|---|---|---|
| 날짜·context 별칭·정책 커밋 | 미실행 | 미실행 |
| CNI·agent 버전/enableNetworkPolicy | 미실행 | 미실행 |
| auth Rollout·migration Job 정책 적용 범위 | 미확인 | 미확인 |
| 양성 리스너·전체 Ready replica 확인 | 미실행 | 미실행 |
| Pod TCP 조합 수 / 허용 / 차단 / 누락·실패 | 미실행 | 미실행 |
| 다른 namespace·monitoring 흉내 차단 | 미실행 | 미실행 |
| Service ClusterIP 업무 호출 | 미실행 | 미실행 |
| ALB 5개 대상 health / TLS·업무 요청 | 해당 없음 | 미실행 |
| recommend 외부 접근 차단 / dev 비공개 | 미실행 | 미실행 |
| RDS·외부 의존 기능 유지 | 미실행 | 미실행 |
| 시험 자원 정리 | 미실행 | 미실행 |

`--keep`는 수동 조사 때만 쓴다(여러 Deployment가 남으면 Quota 초과 가능). 정상 종료/예외 시에는 자기 실행의 자원만 지운다. 강제 종료 시 출력된 `ureka-netpol-probe=<run>` selector와 생성한 임시 namespace를 확인해 **자기 실행 것만** 정리한다. 광범위한 namespace selector 삭제는 하지 않는다. 결과 표·건수만 공유하고 내부 패킷 IP/원문 로그를 공개하지 않는다.

## 되돌리기

문제가 생겨도 VPC 전체·namespace 전체를 즉시 허용하지 않는다. 공개를 잠시 중단하고 원인/필요 경로를 확인해 정책을 수정한다. dev는 검증한 Git revert로, prod는 검토한 revert 뒤 수동 Sync한다. Argo 앱 삭제만으로 정책이 제거되지는 않는다. default deny만 따로 제거하면 미지정 Pod가 열릴 수 있으므로 허용 정책과 묶어서 변경하고 다시 차단 시험한다.

## 근거

- [AWS EKS NetworkPolicy](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html)
- [AWS VPC CNI troubleshooting — Deployment 제약·PolicyEndpoint](https://docs.aws.amazon.com/eks/latest/userguide/network-policies-troubleshooting.html)
- [AWS PolicyEndpoint 타입 정의](https://github.com/aws/amazon-network-policy-controller-k8s/blob/main/api/v1alpha1/policyendpoint_types.go)
- [Kubernetes NetworkPolicy — ipBlock·NAT·노드 예외](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- EC2 기존 정책·기대 표: `environments/ec2/dev/networkpolicy/`, `tests/networkpolicy/expected.json`.
