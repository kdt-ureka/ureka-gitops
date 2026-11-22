# EKS 앱 구성: root 앱·AppProject·dev/prod 서비스 (#43)

EKS에서도 Git으로만 배포되게 하는 Argo CD 구성이다. Argo CD 설치 도구는 [eks-argocd.md](eks-argocd.md)(#87)를 본다.
이 문서는 CN 담당이 교차 검토 뒤 실행할 절차다. 작성 때 클러스터·AWS 변경은 하지 않았다.
클러스터·AWS 변경은 교차 검토와 파트장 승인 뒤 파트장이 직접 한다.

선행 변경: #62(네임스페이스·Quota·prod 사람 권한), #63(Secrets Manager·ESO). 이 둘이 main에 먼저 병합돼야 한다.
외부 공개(ALB·도메인·인증서)는 #64, NetworkPolicy는 #49 범위라 여기에 없다.

## 한눈에

```
argocd/eks/root-app.yaml (등록 도구가 ECR 주소를 넣어 한 번 등록, 자동 동기화)
└─ argocd/eks/apps (helm 차트)
   ├─ AppProject 3개 (wave -3)
   ├─ ureka-eks-namespace-{dev,prod}  → environments/eks/<env>/namespace (#62)     wave -2, 자동
   ├─ ureka-eks-data-{dev,prod}       → environments/eks/<env>/data                wave -1, dev 자동 / prod 수동
   └─ ureka-<서비스>-eks-{dev,prod}   → charts/ureka-backend + base + eks/<env>    wave 0,  dev 자동 / prod 수동

손으로 한 번 등록하는 앱(root에 넣지 않음, 지워지면 안 되는 도구):
  argocd/eks/argo-rollouts-app.yaml  (auth 카나리 컨트롤러)
  argocd/eks/external-secrets-app.yaml, secrets-{dev,prod}-app.yaml  (#63)
```

이미지 흐름: **EC2 dev 확인 → EKS dev(같은 digest) → EKS prod(같은 digest)**. 단계마다 gitops PR이 따로 있다.
EKS dev가 EC2 dev보다 잠깐 늦는 것은 정상이다. 검사가 다른 이미지를 안내(notice)로 보여 준다.

## 파일

| 경로 | 내용 |
|---|---|
| `argocd/eks/root-app.yaml` | root 앱. `ecrRegistry`는 Git에서 빈칸이다 |
| `argocd/eks/apps/` | AppProject 3개와 Application 목록(helm). 환경·서비스 목록은 `values.yaml` |
| `argocd/eks/argo-rollouts-app.yaml` | Argo Rollouts 2.43.12(EC2와 같음), 손으로 등록 |
| `environments/eks/{dev,prod}/ureka-*.yaml` | 서비스 values. base 위에 겹친다 |
| `environments/eks/{dev,prod}/data/` | Service postgres(같은 RDS)·Redis·Mailpit |
| `scripts/eks/register_root_app.py` | root 앱 등록(계정 ID는 환경 변수, kubectl 표준 입력으로만) |
| `tests/eksapps/check_eks_apps.py` | EKS 정책 검사(`scripts/check-charts.sh`가 실행) |
| `charts/ureka-backend` `envOverrides` | env 일부 값만 바꾸는 칸(아래) |

## AppProject

앱이 만들 수 있는 자원을 줄인다. 허용 목록 밖 자원은 Argo CD가 동기화 때 거부한다.

| 프로젝트 | 쓰는 앱 | 목적지 | 클러스터 범위 | 네임스페이스 범위 |
|---|---|---|---|---|
| `ureka-eks-platform` | 네임스페이스 앱 2개 | dev, prod | Namespace | ResourceQuota, LimitRange, Role, RoleBinding |
| `ureka-eks-dev` | dev 데이터·서비스 | dev | 없음 | Service, Deployment, Job, Rollout |
| `ureka-eks-prod` | prod 데이터·서비스 | prod | 없음 | 위와 같음 |

- 저장소는 이 저장소 하나만 허용한다.
- 플랫폼 프로젝트를 따로 둔 이유: Namespace는 이름으로 제한할 수 없다. 이미지 PR이 자주 드나드는 서비스 앱이 Pod Security 라벨·Quota·권한을 바꾸지 못하게 한다.
- 업무 프로젝트에는 Secret·권한(Role 등)·ServiceAccount가 없다. Secret은 #63 ESO만 만든다.
- Ingress(#64)·NetworkPolicy(#49)는 그 변경에서 업무 프로젝트 허용 목록에 더한다.
- 업무 프로젝트는 `orphanedResources.warn`을 켠다. Git에 없는 자원이 생기면(사람이 직접 만든 자원) Argo CD 화면에 경고가 뜬다.
- root 앱과 #63의 비밀 연결 앱·Rollouts·ESO 앱은 `default` 프로젝트다(AppProject·Application·클러스터 범위 자원을 만들어야 함).
  `default` 프로젝트 제한은 후속이다(지금 Argo CD 계정은 admin 하나).

### prod auth 카나리 승격·중단

#62에서 사람의 Kubernetes Rollout patch 권한을 뺐다(patch는 이미지·Pod 템플릿도 바꿀 수 있음).
대신 `ureka-eks-prod` 프로젝트에 `auth-rollout-operator` 역할을 둔다.

- 허용: `ureka-auth-eks-prod` 앱 조회, Rollout 동작 `resume`·`promote-full`·`abort`·`retry`
- 없음: sync·update·delete·로그·exec, 다른 앱
- `groups`가 비어 있어 지금은 아무에게도 붙지 않는다. 사람별 Argo CD 계정(SSO 등)이 생기면 플랫폼 담당 그룹을 넣는 PR을 한다.
  그 전까지 prod 승격·중단은 관리자가 Argo CD 화면에서 한다.

## 동기화 방식

| | dev | prod |
|---|---|---|
| 네임스페이스 앱 | 자동(prune·selfHeal) | 자동(prune·selfHeal) |
| 데이터·서비스 앱 | 자동(prune·selfHeal) | **수동 Sync** |

- **prod 수동 Sync 근거**: 바뀌는 내용은 Git PR로만 정하고, 공개 환경에 반영하는 시점은 사람이 Argo CD에서 Sync로 따로 승인한다.
- 네임스페이스 앱은 prod도 자동이다. Pod Security·Quota·권한은 안전장치라서, 손으로 바뀌면 바로 되돌려야 한다.
- root 앱은 자동이다. Application 정의만 맞추므로, prod 자원은 사람이 Sync하기 전까지 바뀌지 않는다.
- prod 수동 Sync에서는 selfHeal이 없다. 누가 prod를 직접 바꾸면 OutOfSync로 보이기만 한다. #62 권한으로 사람의 직접 쓰기를 막는다(클러스터 관리자 제외).
- 남는 위험: Argo CD 관리자는 Sync할 때 main이 아닌 revision을 고를 수 있다. prod Sync는 main 그대로만 한다(화면에서 Revision 칸을 바꾸지 않는다).

## 환경별 값

| | EC2 dev(참고) | EKS dev | EKS prod |
|---|---|---|---|
| 이미지 | — | EC2 dev와 같은 tag·digest | EKS dev와 같은 tag·digest |
| 파드 수 | auth 2, 나머지 1 | **모두 1** | auth 2, 나머지 1 |
| auth | Rollout, CPU 120m(시험값) | Rollout, **CPU 100m** | Rollout, **CPU 100m** |
| DB | RDS `<db>`, `<db>_app` | 같음 | 같은 RDS의 `<db>_prod`, `<db>_prod_app` |
| frontend 넘김 주소 | `*.dev.svc` | 같음 | `*.prod.svc` |
| `COOKIE_SECURE` | false | false | **true** |
| 메일 | Mailpit | Mailpit | Mailpit(아래 후속) |
| 외부 노출 | Traefik Ingress(SSM 터널) | 없음 | 없음(#64에서 ALB) |

이미지 tag(11/22): auth `fb92c50`, chat·chat-worker `9e87f39`, recommend `f5c02c3`, content `4790011`, ops `895b3c0`, frontend `3344d57`.

- dev 카나리: 파드가 1개라 새 이미지가 오면 새 파드 1개가 더 뜨고(옛 1 + 새 1) 멈춘다. 승격·중단 연습은 그대로 된다.
- prod `COOKIE_SECURE=true`: 공개 주소가 https라서다. #64 전에는 `localhost` 포트 포워딩으로만 확인한다(브라우저가 localhost를 안전한 주소로 취급).
- Secret 이름·키는 dev·prod가 같다. 값만 환경별 원본(#63 `ureka/eks/<env>/…`)이다. values에는 비밀값이 없다.
- `RECOMMEND_COMPLETION_RESERVE_SECONDS=2`(chat)는 base의 dev 임시값을 prod도 그대로 쓴다. 운영값은 실측 뒤 chat 담당과 정한다.

### envOverrides (차트)

Helm은 env 목록을 합치지 못하고 통째로 바꾼다. prod가 base env 전체를 복사하지 않고 다른 값만 바꾸도록 `charts/ureka-backend`에 `envOverrides`(이름 → 문자열)를 더했다.

```yaml
envOverrides:
  DB_URL: jdbc:postgresql://postgres:5432/auth_db_prod
```

- 순서와 나머지 항목은 그대로다(`$(DB_PASSWORD)` 치환 순서 유지). Deployment·Rollout·마이그레이션 Job이 같이 쓴다.
- env에 없는 이름, Secret 참조(`valueFrom`) 항목, 문자열이 아닌 값은 렌더링이 실패한다.
- 기존 kind·EC2·차트 시험 values의 렌더 결과는 바이트 단위로 같다(변경 전후 비교).

### 데이터 계층

- `environments/ec2/dev/data`를 그대로 쓰고 네임스페이스만 바꾼다. Service `postgres`는 EC2와 같은 RDS를 가리키는 ExternalName이다.
- DB 계정은 여기서 만들지 않는다. dev는 EC2와 같은 계정이고, prod 계정·DB 생성은 #63 후속 bootstrap이다.
- Redis·Mailpit은 네임스페이스마다 따로다(dev·prod가 로그인 토큰·캐시·메일을 공유하지 않는다).
- 둘 다 `Recreate`로 바꿨다. 볼륨이 없어 롤링 업데이트로 새 파드를 먼저 띄워도 데이터가 이어지지 않고, Quota만 더 쓴다.

## Quota (데이터 계층 포함)

`check_eks_apps.py`는 #62 검사기와 같은 기준(모든 앱 동시 갱신 + auth 카나리 새 파드 + chat 마이그레이션 Job)에 데이터 계층까지 더한다.

| | 요청 CPU·메모리 | 상한 CPU·메모리 | 파드 | #62 Quota(11/22 `d10f0fc`) |
|---|---|---|---|---|
| dev | 1420m · 4128Mi | 11.2코어 · 7552Mi | 17 | 1600m·5Gi / 12코어·9Gi / 20 |
| prod | 1520m · 4640Mi | **12.2코어** · 8320Mi | 18 | 1600m·5Gi / **12코어**·9Gi / 20 |

prod 상한 CPU가 Quota보다 0.2코어 많다. #62 계산에 Redis·Mailpit(상한 700m)이 빠져 있어서다.
#62에서 prod `limits.cpu`를 13으로 올려야 이 검사가 통과한다(교차 검토 요청서). 요청 CPU도 95%라 여유가 적다.

## 켜는 순서 (EKS 켠 뒤, CN 실행)

1. #42 EKS apply, data SG에 새 노드 SG 반영(plan에 DB 교체 없음).
2. Argo CD 설치([eks-argocd.md](eks-argocd.md)), 초기 비밀번호 변경.
3. Argo Rollouts: `kubectl --context ureka-eks apply -f argocd/eks/argo-rollouts-app.yaml` → Argo CD에서 Sync → 컨트롤러 Ready.
4. ESO와 dev 비밀 연결([eks-secrets.md](eks-secrets.md)). dev 네임스페이스는 root 앱이 만들므로, #63 등록 도구가 dev 네임스페이스를 요구하면 5번 뒤에 한다.
5. root 앱 등록. 승인 계정 ID는 명령 인자가 아니라 환경 변수로만 넘긴다(승인된 로컬 설정에서 읽는다).

   ```sh
   python3 scripts/eks/register_root_app.py check --profile ureka-admin
   python3 scripts/eks/register_root_app.py apply --profile ureka-admin --confirm-cluster ureka-eks
   ```

   계정·EKS ACTIVE·kubectl context·Argo CD·Rollouts CRD를 확인한다. check는 서버 dry-run이라 바뀌지 않는다.
   실패해도 kubectl 출력은 보여 주지 않는다(ECR 주소에 계정 ID가 있음).
6. 확인(값 없이)
   - `ureka-eks-namespace-*` Synced·Healthy, dev·prod 네임스페이스 Pod Security 라벨
   - dev 앱 전부 Synced·Healthy. chat 마이그레이션 Job Completed, auth Rollout Healthy
   - prod 앱은 OutOfSync(수동 Sync 대기)
   - `kubectl --context ureka-eks -n dev get pods`: 재시작 0. DB 인증 실패가 없는지 로그로 확인(비밀값은 로그에 없다)
7. prod 첫 Sync는 #63 후속(prod DB·계정 bootstrap, prod 비밀 시드·등록)이 끝난 뒤에 한다.
   순서: `ureka-eks-data-prod` → `ureka-auth-eks-prod`·`ureka-content-eks-prod`·`ureka-ops-eks-prod`·`ureka-recommend-eks-prod` → `ureka-chat-eks-prod` → `ureka-frontend-eks-prod`.
   그 전에 Sync하면 DB 인증 실패로 파드가 재시작을 반복한다(옛 파드가 없어 서비스 영향은 없다).

## Git 되돌리기 시험 (#43 완료 기준)

dev에서 한다. prod에는 사람이 Sync를 눌러야 반영되므로 같은 시험을 prod Sync로 한 번 더 확인한다.

1. 시험 PR: dev의 서비스 하나(예: ops)에서 바뀌어도 안전한 값 하나를 바꾼다. 이미지 digest는 바꾸지 않는다.
2. 병합 → Argo CD가 자동 Sync → 새 파드가 뜨는지 확인한다(시각 기록).
3. GitHub에서 그 PR을 Revert하는 PR → 병합 → 원래 값의 파드로 돌아오는지 확인한다(시각 기록).
4. auth 카나리는 따로: 새 이미지를 dev에 넣으면 50%에서 멈춘다 → Argo CD에서 `abort`(즉시 차단) → Revert PR(영구 복구).

## 아직 확인하지 않은 것

- 실제 EKS에서 Argo CD가 AppProject 허용 목록 밖 자원을 거부하는지, Namespace 이름을 목적지로 검사하는지(Argo CD 3.6)
- AppProject 역할 `auth-rollout-operator`로 Rollout 동작만 되고 sync·update는 거부되는지(사람별 계정이 생긴 뒤)
- Redis·Mailpit·서비스·Rollouts 컨트롤러가 EKS 1.37 Pod Security restricted를 통과하는지(렌더링으로는 보안 설정 확인)
- 노드가 ECR에서 이미지를 받는지(노드 역할 `AmazonEC2ContainerRegistryPullOnly`), RDS DNS 이름 풀이·접속
- 실제 메모리·CPU 사용량, 노드 2대에 두 환경이 다 들어가는지
- prod 메일: **사용성 테스트는 가입 흐름 포함·원격 공개 링크로 확정**됐다. 공개 전 SES(magonjal.com) 실제 메일이 필요하다(CN 후속).
  지금 prod Mailpit은 메일을 받기만 해서 실제 사용자는 가입 인증 메일을 받지 못한다.

## 검사 (클러스터·AWS 불필요)

```sh
bash scripts/check-charts.sh          # EKS 렌더링·정책 검사(tests/eksapps)와 자체 시험 포함
bash scripts/test-chart-options.sh    # envOverrides 포함 차트 선택 칸
python3 -m unittest discover -s tests/eks
bash scripts/check-forbidden-files.sh
```

`check-charts.sh`의 EKS 검사:

- AppProject: 3개, 저장소 하나, 목적지 고정, 업무 프로젝트에 클러스터 자원·Secret·권한 없음, prod 역할은 auth Rollout 동작만
- Application: 프로젝트·목적지·values 경로가 자기 환경, main 브랜치, dev·네임스페이스 자동, prod 업무 앱 수동
- 렌더된 자원 종류가 프로젝트 허용 목록 안, 다른 네임스페이스 자원·LoadBalancer·NodePort 없음
- prod는 `_prod` DB·`_prod_app` 계정·`.prod.svc` 주소만, dev는 반대. 비밀 env는 Secret 참조만
- dev 모두 1개, auth Rollout·CPU 100m, prod auth 2개, 이미지 digest 고정
- Quota 안(데이터 계층 포함, #62 네임스페이스가 있을 때)

자체 시험(`tests/eksapps/test_check_eks_apps.py`)은 값 하나씩 망가뜨린 입력이 실패하는지 본다.
#62가 병합되기 전에는 네임스페이스 경로가 없어서 `check-charts.sh`가 실패한다(병합 순서: #62 → #63 → 이 변경).
