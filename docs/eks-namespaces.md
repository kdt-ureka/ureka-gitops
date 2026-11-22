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
| `environments/eks/prod/rbac/` | 사람 권한 Role 2개·RoleBinding 2개 |
| `scripts/test-eks-namespaces.sh` | 정적 시험(CI Helm 워크플로) |
| `scripts/test-eks-namespaces-kind.sh` | 임시 kind 클러스터 실제 거부 시험(로컬 전용) |

## Pod Security

EC2 dev와 같은 라벨: `enforce=restricted`(`enforce-version=latest`), `warn=restricted`, `audit=restricted`.
비root·권한 상승 금지·capability 제거·seccomp를 지키지 않는 Pod, `privileged`·`hostNetwork`·`hostPath` Pod는 만들 수 없다.
EKS 노드는 IMDS hop limit 1이지만 hostNetwork Pod는 IMDS(노드 IAM 역할)에 닿을 수 있다. 이 라벨이 그 경로를 막는다.
Namespace에는 `Prune=false`를 붙여, Application에서 파일이 빠져도 네임스페이스와 안의 앱이 지워지지 않게 했다.
`argocd` 네임스페이스는 upstream 설치 manifest 때문에 baseline 강제(restricted는 경고·감사)로 따로 둔다(#87).

## 자원 상한 계산

### 서비스 7개 (EC2 dev values 기준, EKS values는 #43에서 같은 값으로 시작)

| | CPU 요청 | 메모리 요청 | CPU 상한 합 | 메모리 상한 합 | 파드 |
|---|---:|---:|---:|---:|---:|
| 평상시 (auth 2개, 나머지 1개) | 790m | 2464Mi | 6000m | 4224Mi | 8 |
| 최대: auth 카나리 새 파드 1개 + chat 마이그레이션 Job | 960m | 3104Mi | 7500m | 5376Mi | 10 |

카나리는 트래픽 라우팅 없는 canary라 새 파드가 먼저 뜬 뒤(maxSurge 25% → 1개) 옛 파드를 줄인다.
EC2 실측(노드 메모리 request 41%, 카나리 중 약 55%)과 같은 흐름이다.

### Quota와 LimitRange

| | dev | prod |
|---|---|---|
| requests.cpu / limits.cpu | 1200m / 8 | 1500m / 9 |
| requests.memory / limits.memory | 3584Mi / 6Gi | 4608Mi / 7Gi |
| pods | 15 (ingest Job·파일 Pod 포함) | 16 |
| services.loadbalancers / nodeports | 0 / 0 | 0 / 0 |
| PVC / 저장 용량 | 2개 / 20Gi (ingest 원본·결과) | 0 |

- 카나리 최대치 대비 prod는 메모리 요청 67%, dev는 87%다. prod 여유로 frontend 2개나 ingest 1회 정도를 더 띄울 수 있다.
- dev에서는 ingest와 카나리를 동시에 돌리지 않는다(메모리 상한 합이 6Gi를 넘는다).
- prod PVC 0: content를 prod에 재적재(ingest)하기로 정하면 이 값을 PR로 올린다. 복사 방식이면 그대로 둔다.
- 공개는 #64 ALB Ingress(target-type ip)로만 한다. LoadBalancer·NodePort Service는 Quota 0으로 만들 수 없다.
- LimitRange(컨테이너 하나, 두 환경 같음): 값을 적지 않으면 요청 50m·64Mi, 상한 500m·256Mi가 들어간다. 최대는 1코어·1Gi다.
  지금 가장 큰 컨테이너는 1코어·768Mi(auth·content·ops)이고 ingest Job이 1Gi다.

### 클러스터 용량 (t3.large 2대, 추정)

노드 하나의 allocatable은 약 1930m·7100Mi로 추정했다(EKS AL2023 기본 예약을 뺀 값이며 실측 전이다).
시스템(kube-system·Argo CD·Argo Rollouts·관측) 요청은 약 600m·1.5Gi로 추정했다.

- 두 환경 Quota 요청을 다 채우면 시스템 몫까지 CPU 3300m / 3860m(85%), 메모리 9728Mi / 14200Mi(68%)다.
- 노드 1대가 멈추면 전부 다시 올라오지 못한다. 2대 구성은 HA가 아니다(docs/eks.md).
- EKS를 켜면 실제 값을 확인하고, 다르면 `tests/namespaces/check_eks_namespaces.py`의 상수와 Quota를 함께 고친다.
  - `kubectl describe node`의 Allocatable
  - `kubectl describe quota -n prod`
  - 카나리 중 노드 요청률

## prod 사람 권한 (RBAC)

원칙: **사람은 prod를 직접 바꾸지 않는다. 변경은 Git PR → Argo CD만 한다.**

| 그룹(access entry의 `kubernetes_groups`) | 대상 | 허용 | 없음 |
|---|---|---|---|
| `ureka-prod-viewers` | 팀원 | prod의 Pod·Service·ConfigMap·Event·Deployment·Rollout·Job·Ingress·NetworkPolicy·Quota 등 조회(get/list/watch), `kubectl top pods` | Secret, 로그, exec·attach·port-forward·proxy, 모든 쓰기, dev 네임스페이스 |
| `ureka-prod-rollout-operators` | 플랫폼 담당 | viewers 전부 + `ureka-auth` Rollout과 그 status의 get·patch(승격·중단·재시도) + prod Pod 로그 | Secret, exec, 다른 Rollout·Deployment 변경, 삭제·생성, Role 변경 |

- 로그를 팀원 그룹에서 뺀 이유: chat 등 로그에 사용자 대화 같은 개인 정보가 있을 수 있다. dev 로그는 별도로 정한다.
- 남는 위험: RBAC은 patch할 필드를 제한하지 못한다. 그래서 플랫폼 그룹은 `ureka-auth`의 이미지 같은 다른 필드도 patch할 수 있다.
  - Argo CD selfHeal이 Git 상태로 되돌리고, EKS audit 로그(CloudWatch 7일)에 남는다.
  - 더 강하게 하려면 승격·중단을 Argo CD 화면의 Rollout 동작(Argo CD RBAC 정책)으로만 하고, Kubernetes 쓰기 권한은 주지 않는다.
  - 이 방식은 Argo CD에 사람별 계정(SSO)이 필요하다. 지금은 admin 하나라 후속으로 둔다.
- Kubernetes RBAC은 허용을 더하기만 한다. 클러스터 관리자 access entry(파트장, `AmazonEKSClusterAdminPolicy`)는 이 Role과 관계없이 모든 권한을 가진다. 비상용으로만 쓴다.
  사람의 prod 직접 쓰기를 기술적으로 막으려면 ValidatingAdmissionPolicy(Argo CD·컨트롤러 계정 외 쓰기 거부)를 검토한다(후속, 잘못 만들면 컨트롤러가 멈출 수 있어 별도 시험 필요).
- 그룹 이름이 Rollout 이름(`ureka-auth`)과 묶여 있다. 정적 시험이 prod Rollout이 `ureka-auth` 하나인지 확인한다.

### EKS access entry 설계 (Terraform, 후속 변경)

- `aws_eks_access_entry`: 대상 IAM 역할 하나당 하나씩, `type = "STANDARD"`.
  - 팀원 SSO 권한 세트 역할 → `kubernetes_groups = ["ureka-prod-viewers"]`
  - 플랫폼 담당 SSO 역할 → `kubernetes_groups = ["ureka-prod-rollout-operators"]`
- `aws_eks_access_policy_association`(AWS 관리 정책)은 연결하지 않는다. 권한은 위 Role만 준다.
- 역할 ARN은 비공개 tfvars 변수(예: `prod_viewer_role_arns`, `prod_rollout_operator_role_arns`, 기본값 빈 목록)로 받는다. 계정 ID·ARN은 Git에 쓰지 않는다.
  - SSO 역할 ARN은 경로를 포함한 IAM role ARN이어야 한다(docs/eks.md의 관리자 역할과 같음).
- 팀원은 `aws eks update-kubeconfig`로 접속한다. API 엔드포인트가 관리자 /32로 제한돼 있어 팀원 IP 허용도 함께 정해야 한다.
  지금은 팀원 읽기 권한을 부여하지 않았다(docs/eks.md).

## #43에 넘길 것

- Argo CD Application: `environments/eks/dev/namespace`, `environments/eks/prod/namespace`(kustomize, rbac 포함)를 서비스 앱보다 먼저 동기화한다(sync wave).
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

검사기 자체 시험 24개는 값 하나씩 망가뜨린 입력이 실패하는지 본다.

- 라벨 누락·baseline
- Quota 부족
- LB 허용
- 컨테이너 과대
- viewer에 Secret·로그·쓰기 권한
- operator에 다른 Rollout·update·Deployment 권한
- ClusterRoleBinding
- `system:` 그룹
- Rollout 이름 변경

### 임시 kind 실제 거부 시험 (로컬, 2026-11-22 결과 51/51 통과)

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
  - prod에서 메모리 요청이 누적 5Gi가 되면 거부된다.
- RBAC: `kubectl auth can-i` 표 26개
- 승격·중단 흉내: 시험용 최소 Rollout CRD로 확인했다. 실제 Argo Rollouts 설치는 아니다.
  - operator: `ureka-auth`의 spec patch와 status patch는 허용, `ureka-content` patch는 거부
  - viewer: patch 거부

EKS(1.37)에서는 #43 적용 뒤 같은 확인을 다시 한다. 특히 `kubectl argo rollouts promote/abort`를 플랫폼 그룹으로 실제 실행해 본다.
