# EKS dev·prod 네임스페이스 (#62)

EKS에 `dev`(시험용, 작게: 카나리·NetworkPolicy 시험)와 `prod`(공개: 사용성 테스트·시연) 네임스페이스를 둔다.
이미지는 EC2 dev 확인 → EKS dev(같은 digest) → EKS prod(같은 digest) 순서로 각각 gitops PR로 올린다.
prod DB는 같은 RDS 안의 별도 논리 DB·계정이다(#63). 이 문서는 네임스페이스 정책만 다룬다.

이 변경은 매니페스트와 시험이다. 클러스터 적용은 #43(EKS root 앱·AppProject)에서 Argo CD로 한다.
EKS access entry(IAM ↔ 그룹 연결)는 Terraform 변경이라 아래 설계만 두고 코드는 만들지 않았다.

## 파일

| 경로 | 내용 |
|---|---|
| `environments/eks/dev/namespace/` | Namespace(Pod Security restricted)·ResourceQuota·LimitRange |
| `environments/eks/prod/namespace/` | 같은 3종 + `../rbac`(kustomize로 한 앱에 묶음) |
| `environments/eks/prod/rbac/` | 사람 권한: 조회 전용 Role·RoleBinding 1개씩 |
| `scripts/test-eks-namespaces.sh` | 정적 시험(CI Helm 워크플로) |
| `scripts/test-eks-namespaces-kind.sh` | 임시 kind 클러스터 실제 거부 시험(로컬 전용) |

## Pod Security

EC2 dev와 같은 라벨: `enforce=restricted`(`enforce-version=latest`), `warn=restricted`, `audit=restricted`.
비root·권한 상승 금지·capability 제거·seccomp를 지키지 않는 Pod, `privileged`·`hostNetwork`·`hostPath` Pod는 만들 수 없다.
EKS 노드는 IMDS hop limit 1이지만 hostNetwork Pod는 IMDS(노드 IAM 역할)에 닿을 수 있다. 이 라벨이 그 경로를 막는다.
Namespace에는 `Prune=false`를 붙여, Application에서 파일이 빠져도 네임스페이스와 안의 앱이 지워지지 않게 했다.
`argocd` 네임스페이스는 upstream 설치 manifest 때문에 baseline 강제(restricted는 경고·감사)로 따로 둔다(#87).

`enforce-version=latest`는 EC2와 맞춘 값이다. latest는 API 서버 버전을 따라가므로, 업그레이드 뒤 Pod가 다시 만들어질 때 거부될 수 있다.
kind(1.36.1)는 시험용 Pod로만 확인했고, EKS 1.37 호환은 아직 확인하지 않았다.
#43 적용 전에 EKS 1.37에서 실제 서비스·Job 템플릿이 admission을 통과하는지 확인한다.
재현성이 필요하면 그때 검증한 버전으로 `enforce-version`을 고정하고, 다음 버전은 warn/audit로 먼저 점검한다.

## 자원 상한 계산

### 서비스 7개 (EC2 dev values 기준, EKS values는 #43에서 같은 값으로 시작)

| | CPU 요청 | 메모리 요청 | CPU 상한 합 | 메모리 상한 합 | 파드 |
|---|---:|---:|---:|---:|---:|
| 평상시 (auth 2개, 나머지 1개) | 790m | 2464Mi | 6000m | 4224Mi | 8 |
| 최대: 모든 앱이 동시에 갱신 | 1510m | 4544Mi | 11500m | 8064Mi | 16 |

최대치에 넣은 것:

- Deployment 6개의 롤링 업데이트 추가 파드: 각 1개(기본 maxSurge 25%를 올림)
- auth 카나리 새 파드 1개: 트래픽 라우팅 없는 canary라 새 파드가 먼저 뜬다.
- chat 마이그레이션 Job 1개

동시 갱신을 기준으로 잡은 이유는 두 가지다.

- 이미지 흐름(EC2 dev → EKS dev → EKS prod)에서 한 PR이 여러 서비스 이미지를 한 번에 바꿀 수 있다.
- auth 카나리가 수동 pause로 멈춘 동안 다른 앱이 자동 동기화될 수 있다(교차 검토 필수 2).

검사기는 렌더링된 `strategy`(Recreate·maxSurge)를 읽어 추가 파드를 센다. #43에서 동시 배포를 줄이면 값이 자동으로 바뀐다.
배포를 줄이는 방법은 두 가지다.

- dev surge 0: 다운타임을 감수한다.
- sync 순서 직렬화: 이전 앱 완료 조건을 함께 보장해야 한다.

### Quota와 LimitRange

| | dev | prod |
|---|---|---|
| requests.cpu / limits.cpu | 1600m / 12 | 1600m / 13 |
| requests.memory / limits.memory | 5Gi / 9Gi | 5Gi / 9Gi |
| pods | 20 | 20 |
| services.loadbalancers / nodeports | 0 / 0 | 0 / 0 |
| PVC / 저장 용량 | 2개 / 20Gi (ingest 원본·결과) | 0 |

- 동시 갱신 최대치 대비 CPU 요청 94%, 메모리 요청 89%, CPU 상한 96%, 메모리 상한 88%다.
- 데이터 계층(Redis·Mailpit, #43)도 같은 Quota에 센다. 시험은 `environments/eks/<env>/data`가 있으면 함께 렌더링한다.
  - Recreate 전략이라 배포 중 추가 파드는 없다.
  - #43 prod values 기준 최대치는 요청 1520m·4640Mi, 상한 12.2코어·8320Mi, 파드 18이다. 그래서 prod limits.cpu를 13으로 올렸다(94%).
  - dev는 #43 values 기준 상한 11.2코어라 12로 둔다(93%).
- dev는 prod와 같은 서비스·같은 values라 최대치가 같아서 Quota도 같다. dev를 더 작게 하려면 위의 #43 결정이 먼저다.
- ingest(Job·파일 Pod, 요청 140m·384Mi, 상한 1.7코어·1.75Gi)는 지금 수동 실행이다. 배포 중에는 돌리지 않는다.
  - 평상시와 함께는 들어간다.
  - 동시 갱신과 겹치면 상한을 넘는다.
  - 자동·예약 적재를 붙이면 #43에서 직렬화하거나 용량을 따로 잡는다.
- prod PVC 0이라 지금의 PVC 기반 ingest는 prod에서 실행할 수 없다.
  - content를 prod에 재적재하기로 정하면 이 값을 PR로 올린다.
  - 복사 방식이면 그대로 둔다.
- 공개는 #64 ALB Ingress(target-type ip)로만 한다. LoadBalancer·NodePort Service는 Quota 0으로 만들 수 없다.
- LimitRange(컨테이너 하나, 두 환경 같음)
  - 값을 적지 않으면 요청 50m·64Mi, 상한 500m·256Mi가 들어간다. 최대는 1코어·1Gi다.
  - 지금 가장 큰 컨테이너는 1코어·768Mi(auth·content·ops)이고, ingest Job과 Prometheus가 정확히 1Gi다.
  - 관측은 observability 네임스페이스라 이 LimitRange 대상이 아니다. dev/prod로 옮기면 Quota·PVC까지 다시 계산한다.

### 클러스터 용량 (t3.large 2대, 추정)

노드 하나의 allocatable은 약 1930m·7100Mi로 추정했다(EKS AL2023 기본 예약을 뺀 값이며 실측 전이다).
시스템(kube-system·Argo CD·Argo Rollouts·관측) 요청은 약 600m·1.5Gi로 추정했다.

- 두 환경 Quota 요청을 다 채우면 시스템 몫까지 CPU 3800m / 3860m(98%), 메모리 11776Mi / 14200Mi(83%)다.
  - CPU가 빠듯하다. 다만 이것은 두 환경이 동시에 최대 갱신을 할 때의 상한이고, 평상시 요청은 두 환경 합 1580m이다.
  - 넘치면 Pod가 Pending이 되고, 3대(`desired_nodes=3`)로 늘리거나 dev 배포를 직렬화해 푼다.
- 시스템 추정 600m·1.5Gi 중 관측 차트 세 구성요소가 250m·1024Mi다. 나머지 350m·512Mi로 ESO·Argo CD·Argo Rollouts·EKS 애드온이 충분한지는 확인하지 않았다.
- 노드 1대가 멈추면 전부 다시 올라오지 못한다. 2대 구성은 HA가 아니다(docs/eks.md).
- EKS를 켜면 실제 값을 확인하고, 다르면 `tests/namespaces/check_eks_namespaces.py`의 상수와 Quota를 함께 고친다.
  - `kubectl describe node`의 Allocatable
  - `kubectl describe quota -n prod`
  - 카나리 중 노드 요청률

## prod 사람 권한 (RBAC)

원칙: **사람은 prod를 직접 바꾸지 않는다. 변경은 Git PR → Argo CD만 한다.**

| 그룹(access entry의 `kubernetes_groups`) | 대상 | 허용 | 없음 |
|---|---|---|---|
| `ureka-prod-viewers` | 팀원·플랫폼 담당 | prod 자원 조회(get/list/watch), `kubectl top pods`. 대상: Pod·Service·ConfigMap·Event·Deployment·Rollout·Job·Ingress·NetworkPolicy·Quota 등 | 모든 쓰기(Rollout patch 포함), Secret, ServiceAccount, 로그, exec·attach·port-forward·proxy·ephemeral container, dev 네임스페이스 |

- **auth 카나리 승격·중단은 Kubernetes 권한으로 주지 않는다**(교차 검토 필수 1).
  - Rollout patch는 이름을 `ureka-auth`로 좁혀도 필드를 좁힐 수 없다. 그래서 이미지·Pod 템플릿·Secret 참조를 바꿔 prod에서 다른 코드를 실행하거나 비밀에 간접 접근할 수 있다.
  - selfHeal과 audit는 이미 실행된 변경을 되돌리지 못한다. prod를 수동 동기화로 두면 selfHeal을 전제할 수도 없다.
  - #43에서 사용자별 Argo CD 계정(SSO 등)과 Argo CD RBAC으로 해당 앱의 Rollout 동작(`action/argoproj.io/Rollout/promote-full`·`resume`·`abort`·`retry`)만 연다.
  - 완료 기준: 실제 컨트롤러에서 승격·중단이 동작하고, 같은 사용자의 이미지·템플릿 변경은 적용 전에 거부된다.
  - 그 전까지 prod 승격·중단은 관리자(비상용)가 한다.
- 로그는 이 그룹에서 뺐다. chat 등 로그에 사용자 대화 같은 개인 정보가 있을 수 있다. 플랫폼 담당의 prod 로그 조회는 #43에서 Argo CD 권한과 함께 범위를 정한다.
- ServiceAccount 조회를 뺐다. IRSA 역할 ARN 주석이 보이고, 운영 조회에 필요하지 않다.
- Pod spec·ConfigMap은 평문 값을 그대로 보여 준다. 자격 정보는 반드시 Secret 참조로 넣는다(ESO, #63). #63의 SecretStore·ExternalSecret과 만들어진 Secret은 이 Role로 읽을 수 없다.
- Kubernetes RBAC은 허용을 더하기만 한다.
  - 클러스터 관리자 access entry(파트장, `AmazonEKSClusterAdminPolicy`)는 이 Role과 관계없이 모든 권한을 가진다. 비상용으로만 쓴다.
  - 사람의 prod 직접 쓰기를 기술적으로 막으려면 ValidatingAdmissionPolicy(Argo CD·컨트롤러 계정 외 쓰기 거부)를 검토한다.
  - 후속으로 둔다. 잘못 만들면 컨트롤러가 멈출 수 있어 별도 시험이 필요하다.

### EKS access entry 설계 (Terraform, 후속 변경)

- `aws_eks_access_entry`: 대상 IAM 역할 하나당 하나씩, `type = "STANDARD"`.
  - 팀원·플랫폼 담당 SSO 권한 세트 역할 → `kubernetes_groups = ["ureka-prod-viewers"]`
  - 팀원 역할과 플랫폼 역할은 분리한다(#43에서 Argo CD 권한을 다르게 줄 수 있게).
  - 기존 관리자 access entry와 같은 역할이 아닌지 먼저 확인한다.
- `aws_eks_access_policy_association`(AWS 관리 정책)은 연결하지 않는다. 권한은 위 Role만 준다.
- 역할 ARN은 비공개 tfvars 변수(예: `prod_viewer_role_arns`, 기본값 빈 목록)로 받는다. 계정 ID·ARN은 Git에 쓰지 않는다.
  - SSO 역할 ARN은 경로를 포함한 IAM role ARN이어야 한다(docs/eks.md의 관리자 역할과 같음).
- 팀원은 `aws eks update-kubeconfig`로 접속한다. API 엔드포인트가 관리자 /32로 제한돼 있어 팀원 IP 허용도 함께 정해야 한다.
  kubeconfig 생성에는 IAM 쪽 `eks:DescribeCluster`가 필요하다.
  지금은 팀원 읽기 권한을 부여하지 않았다(docs/eks.md).
- 연결 뒤 실제 역할로 허용(조회)과 거부(Secret·로그·patch)를 각각 확인한다.

## #43에 넘길 것

- Argo CD Application: `environments/eks/dev/namespace`, `environments/eks/prod/namespace`(kustomize, rbac 포함)를 서비스 앱보다 먼저 동기화한다(sync wave).
- auth 카나리 승격·중단: 사용자별 Argo CD 권한으로 Rollout 동작만 연다(위 RBAC 절의 완료 기준).
- 동시 배포 범위: 동시 갱신을 그대로 둘지, dev 직렬화·surge 0으로 dev Quota를 줄일지 정한다.
- ingest를 자동·예약 실행하면 배포와 직렬화한다.
- EKS 1.37에서 실제 서비스·Job 템플릿의 Pod Security admission을 확인한다. `enforce-version` 고정 여부도 정한다.
- 노드 allocatable·시스템 Pod 요청을 실측해 검사기 상수와 Quota를 대조한다.
- AppProject 허용 목록
  - 클러스터 범위: `Namespace`
  - 네임스페이스 범위: `ResourceQuota`·`LimitRange`·`Role`·`RoleBinding`과 서비스 자원
  - `ClusterRole`·`ClusterRoleBinding`은 허용하지 않는다.
- prod 서비스 values(`environments/eks/prod/ureka-*.yaml`)를 만들면 정적 시험이 EC2 dev values 대신 자동으로 그 값을 본다.

## NetworkPolicy 메모 (#49 범위)

이 변경에는 NetworkPolicy가 없다. EKS VPC CNI에서 `enableNetworkPolicy=true`만으로는 기본 거부가 아니다.
#49에서 dev·prod 각각 기본 거부 + EC2 허용 표를 옮기고 재시험한다.
prod는 dev와 서로 통신하지 않게 네임스페이스 단위 허용만 둔다(`kubernetes.io/metadata.name` 라벨은 자동으로 붙으므로 추가 라벨은 필요 없다).

## 시험

### 정적 시험 (CI, 클러스터 없음)

```sh
bash scripts/test-eks-namespaces.sh
```

서비스 7개를 각 환경 values로 렌더링한 뒤 다음을 확인한다.

- Pod Security 라벨이 EC2 dev와 같은지
- 카나리 최대치가 Quota 안에 들어가는지
- 모든 컨테이너가 LimitRange 최대 이하인지
- LB·NodePort가 0인지
- 두 환경 합이 노드 용량 추정 안에 들어가는지
- prod RBAC이 최소 권한인지

검사기 자체 시험 26개는 값 하나씩 망가뜨린 입력이 실패하는지 본다.

- 라벨 누락·baseline
- Quota 부족: 옛 계산(카나리+Job만)으로는 들어가지만 동시 갱신은 못 담는 값 포함
- LB 허용
- 컨테이너 과대
- viewer에 Secret·로그·ServiceAccount·ephemeral container·쓰기 권한, 이름을 좁힌 Rollout patch
- 운영자 그룹 다시 추가
- ClusterRoleBinding
- `system:` 그룹
- surge 계산 단위 시험

### 임시 kind 실제 거부 시험 (로컬, 2026-11-22 검토 반영 뒤 49/49 통과)

```sh
kind create cluster --name ureka-ns62-test --kubeconfig "$TMPDIR/ns62.kubeconfig"
KUBECONFIG="$TMPDIR/ns62.kubeconfig" bash scripts/test-eks-namespaces-kind.sh
kind delete cluster --name ureka-ns62-test --kubeconfig "$TMPDIR/ns62.kubeconfig"
```

스크립트는 context가 `kind-ureka-ns62-test`가 아니면 멈춘다. kind 서버 v1.36.1에서 다음을 확인했다.

- Pod Security: privileged·hostPath+hostNetwork·securityContext 없는 Pod는 거부되고, restricted를 지키는 Pod는 허용된다.
- LimitRange: 기본값이 들어가고, 2Gi 컨테이너는 거부된다.
- Quota
  - LoadBalancer·NodePort Service는 거부되고 ClusterIP는 허용된다.
  - PVC는 prod에서 거부되고 dev에서 허용된다.
  - prod 메모리 요청은 누적 5Gi까지 허용되고 6Gi에서 거부된다.
- RBAC: `kubectl auth can-i` 표 23개. 운영자 그룹 이름은 권한이 하나도 없다.
- 직접 변경 거부: 시험용 최소 Rollout CRD로 확인했다. 실제 Argo Rollouts 설치는 아니다.
  - viewer·운영자 그룹 모두 `ureka-auth`의 이미지 변경·승격(spec patch)·중단(status patch)이 거부된다.

EKS(1.37)에서는 #43 적용 뒤 같은 확인과 Argo CD 권한의 승격·중단 시험을 한다.
