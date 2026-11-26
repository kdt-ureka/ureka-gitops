# EKS 공통 운영 도구 (#42)

특정 PC·worktree 이름에 의존하지 않는다. 저장소를 내려받고 아래 준비를 한 운영 담당자가
직접 실행한다. Python 3.10 이상(표준 라이브러리만), Git, AWS CLI v2, 저장소가 요구하는
Terraform 버전이 필요하다. `--help`와 안전 시험은 AWS에 연결하지 않는다.

## 준비

1. AWS SSO로 로그인한다. 지정 계정의 EKS 생성·삭제, IAM, EC2/VPC, 로그 관리 및
   Terraform S3 상태 읽기·쓰기/잠금 권한이 필요하다. 읽기 전용 권한으로 apply할 수 없다.
2. `infra/environments/eks/{backend.hcl,terraform.tfvars}`를 각 예제에서 준비한다.
   실제 버킷·계정·역할 ARN·현재 공인 IPv4 /32는 운영 담당자가 비공개 파일에 입력한다.
   상태 key는 `eks/terraform.tfstate`로 다른 스택과 분리한다. 계정 허용 목록은 승인 계정 하나로 한다.
3. 서울의 EKS 버전·애드온·AMI를 조회하고 고정한다. 조회 방법은 `docs/eks.md`를 따른다.
4. network의 `route=[]` 소유권 변경을 검토한다. network plan에 교체가 없어야 한다.
   변경이 필요하면 PR 병합 후 담당자가 network부터 적용한다. 이 도구는 EKS 스택만 관리한다.
5. 저장소 루트에서 아래 명령을 실행한다. 다른 PC에서는 같은 원격 상태 저장소를 사용하되,
   본인 SSO 역할·허용 IP를 별도 승인받아 준비한다. 동시에 운영하지 않는다.

아래 환경 변수는 본인의 승인된 값으로 로컬에서 준비한다. 계정 ID·ARN·IP·버킷 이름과
`.local/`의 로그·검토 기록은 공개 게시하거나 커밋하지 않는다.

```sh
export UREKA_OPS_PROFILE=ureka-admin
# 승인 계정 ID를 화면에 표시하지 않고 입력한다(bash/zsh).
read -r -s UREKA_EXPECTED_ACCOUNT_ID
export UREKA_EXPECTED_ACCOUNT_ID
```

`TF_VAR_*`, `TF_CLI_ARGS*`, `TF_DATA_DIR`, `TF_PLUGIN_CACHE_DIR`는 해제한다.
다른 초기화 폴더·provider 캐시를 우회 사용하지 않도록 값이 있으면 실행을 거부한다.
default workspace·서울 리전만 지원한다.
정적 AWS 자격 환경 변수는 하위 명령에서 제거하고 명시한 프로필을 사용한다.

## 생성·변경 계획 (AWS 리소스 변경 없음)

```sh
python3 scripts/eks/operate.py plan \
  --profile "$UREKA_OPS_PROFILE" \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
```

계정 조회 → backend 초기화 → validate → 저장 plan → 검사 순서다. 초기화는 S3 상태와
연결하며 backend 이전·workspace 생성은 하지 않는다. 생성 계획에 삭제·교체가 있으면 중단한다.
계획은 `.local/eks/review-…/`에 저장되고, 폴더 경로와 확인값이 출력된다.
`review.json`에는 계정·로그인 주체 ARN(SSO 세션 이름)이 포함되므로 공유하지 않는다.
그 폴더의 `plan.log`에서 자원별 변경·권한·비용을 직접 검토한다. 숫자 합계만 보고 승인하지 않는다.
오류는 `.local/eks/last-error.log`에 저장된다. 실패 로그도 비공개다.

## 검토한 계획 적용 (실제 AWS 변경)

PR 리뷰·병합 뒤 실행 코드가 최신 `origin/main`과 같은 상태에서 **새 plan을 만들고 검토**한다.
도구는 적용 직전에 main을 fetch하고 EKS 관련 코드가 같은지 확인한다.
작업 브랜치 이름이나 로컬 경로 자체는 제한하지 않으며, 커밋하지 않은 변경은 거부한다.

```sh
python3 scripts/eks/operate.py apply \
  --profile "$UREKA_OPS_PROFILE" \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID" \
  --review-dir .local/eks/review-REPLACE \
  --confirm REPLACE_WITH_REVIEW_HASH
```

코드·비공개 설정·plan 해시·계정·로그인 주체·1시간 유효 시간을 검사한다.
`--confirm`은 plan 때 출력된 검토 확인값이다. 이 명령이 실제 apply 승인이다.
확인값은 실수를 막는 장치이며 인증 수단이 아니다. 실제 권한은 AWS SSO·IAM으로 통제한다.
plan 파일은 Terraform 자체의 상태 잠금·오래된 상태 검사도 거친다.
실행 결과는 같은 폴더의 `apply.log`에 실시간 기록하고, 화면에는 30초마다 진행 중임을 표시한다.
실패 원본은 같은 폴더의 `apply-error.log`에도 보존한다. 성공·실패와 관계없이 같은 plan 재사용을 막는다.
`result.json`에는 시작·종료 Unix 시각과 소요 초·Terraform 성공 여부를 기록한다(#67).
EKS 생성·삭제는 10~20분 이상 걸릴 수 있다. 완료 전에 임의로 중단하거나 같은 명령을
다시 실행하지 않는다. 상세 출력은 비공개 `apply.log`에서 로컬로 확인한다.
실패하면 상태·오류 로그를 확인한 후 새 plan을 만든다. 자동 재시도하지 않는다.

EKS 생성 뒤 data의 EKS 노드 SG 참조 추가·plan·apply는 기존 절차대로 별도 수행한다.
data plan에 RDS·SG 교체가 없는지 확인한다. 이 도구는 data를 자동으로 바꾸지 않는다.

## 상태 조회 (AWS 리소스 변경 없음)

```sh
python3 scripts/eks/operate.py status \
  --profile "$UREKA_OPS_PROFILE" \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
```

AWS의 클러스터·관리형 노드 그룹 상태를 조회한다. 실제 Node/Pod Ready·애드온 동작은
`kubectl`로 별도 확인한다. 이 도구는 kubeconfig를 자동 변경하지 않는다.

## 삭제 계획과 적용 (삭제 적용은 실제 AWS 변경)

운영 문서대로 앱 자동 재생성을 멈추고 LB·PVC를 정리한다. data의 노드 SG 참조를
제거·적용한 뒤 진행한다. 보관할 데이터는 미리 백업한다.

```sh
python3 scripts/eks/operate.py destroy-plan \
  --profile "$UREKA_OPS_PROFILE" \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID" \
  --confirm-cleanup ureka-eks
```

`--confirm-cleanup`은 실제 클러스터 이름으로, 앱·LB·PVC 정리를 직접 확인했다는 뜻이다.
도구는 노드 SG를 인바운드에서 참조하는 외부 SG가 남으면 거부한다(노드 자체·클러스터 SG 제외).
**LB·PVC·데이터 정리 자체를 자동으로 수행하거나 완료를 보증하지는 않는다.**
다만 이 클러스터 컨트롤러가 만든 ALB(`elbv2.k8s.aws/cluster` 태그)가 남아 있으면 destroy plan 전에 멈춘다([공개 입구](../../docs/eks-public.md)).
생성된 삭제 plan을 검토한 뒤 같은 `apply` 명령에 새 경로·확인값과
`--confirm-cleanup ureka-eks`를 추가한다. 적용 직전 같은 SG 참조를 다시 확인한다.

삭제 후 NAT·EIP·ENI·LB와 프로젝트 EBS 잔존을 직접 조회한다. 필요한 retained 볼륨을
무조건 지우지 않는다. Terraform이 소유하지 않는 자원까지 없어졌다고 가정하지 않는다.
network/data/shared 전체를 destroy하지 않는다. 이 도구는 EC2 켜기·끄기도 수행하지 않는다.

### 부분 적용 복구

outputs가 없거나 적용이 실패했으면 자동 삭제·재시도를 하지 않는다. `status`와 AWS 콘솔에서
클러스터·노드 그룹·NAT·EIP·SG 등 남은 자원을 확인하고, `terraform state list`로 이 스택이
관리하는 자원을 대조한다. 콘솔에 있지만 state에 없는 자원은 교차 검토 후 import·정리 방법을
정한다. 출력이 없다는 이유로 수동 삭제하지 않는다. 담당자와 상태를 확인한 뒤 새 plan을
검토하며, outputs가 없어 도구의 삭제 검사를 통과할 수 없으면 별도 검토한 수동 복구 절차를 따른다.

## EKS 비밀 연결 등록 (#63)

`register_secrets_app.py check|apply --env dev|prod`는 승인 계정 ID를 `argocd/eks/secrets-<env>-app.yaml`의 빈칸에
메모리에서 넣어 kubectl 표준 입력으로만 등록한다. 절차와 선행 조건은 [EKS 비밀값](../../docs/eks-secrets.md).

prod는 등록 전에 두 도구를 순서대로 쓴다(둘 다 `check`는 변경 없음, 실제 실행은 `--confirm-env prod`).
- `seed_prod_secrets.py check|create`: `ureka/eks/prod/app`을 새 값으로 한 번 만든다. 있으면 멈춘다.
- `bootstrap_prod_db.py check|apply`: 같은 RDS에 `<db>_prod` DB·계정을 만든다(임시 Secret·Job은 끝나면 지우고 확인).

## 안전 시험

```sh
python3 -m unittest discover -s tests/eks -v
```

AWS 호출 없이 잘못된 계정·변경된 plan·미병합 코드·부분 실패 재실행·SG 참조 등 거부 경로를 검사한다.
실제 AWS 생성·삭제 검증은 별도다. 로컬 시험 통과를 실환경 검증으로 쓰지 않는다.

저장 plan 적용은 추가 Terraform 확인 질문 없이 실행되므로, `--confirm`에 검토 확인값을
입력하는 것을 명시 승인으로 사용한다. [Terraform apply 공식 문서](https://developer.hashicorp.com/terraform/cli/commands/apply).

## 켜기·끄기 자동화 도구 (#102)

`lifecycle.py`는 기존 운영 도구의 순서·전제·확인 지점을 묶는다. 외부 변경을 한꺼번에
자동 승인하지 않는다. 기본 실행은 실제 상태를 읽어 완료 단계를 건너뛰고 첫 미완료 단계에서
멈춘다. 실행 후 같은 명령을 다시 쓰면 상태를 재확인하고 이어 간다.

```sh
# 외부 호출도 파일 생성도 없는 순서 미리 보기
python3 scripts/eks/lifecycle.py up --plan-only
python3 scripts/eks/lifecycle.py down --plan-only

# 앞의 준비 절차대로 프로필·승인 계정 입력 후 사용
# 현재 공인 IPv4는 직접 확인해 숨겨 입력(목록·입력값은 도구가 출력하지 않음)
read -r -s UREKA_CURRENT_IPV4
export UREKA_CURRENT_IPV4
python3 scripts/eks/lifecycle.py up
python3 scripts/eks/lifecycle.py down
```

프로필은 `UREKA_OPS_PROFILE` 또는 `--profile`, 계정은 `UREKA_EXPECTED_ACCOUNT_ID`만 쓴다.
각 worktree에서 backend 초기화와 비공개 설정을 준비해야 한다. 다른 worktree의 tfvars,
backend, `.local/`을 복사·수정하지 않는다. 초기 `access` 검사는 Terraform console로
현재 설정과 실제 EKS 관리 허용 목록의 일치 여부만 확인한다. 현재 IP를 외부 서비스에
자동 전송해 알아내지 않는다. kubeconfig 단계 이후에는 계정·ACTIVE 클러스터·API 주소가
실제 대상과 일치해야 하며 노드 Ready도 확인한다. down은 첫 전제 확인부터 Terraform 출력의
클러스터 이름·endpoint·노드 SG를 실제 계정·리전·context와 대조한다. destroy plan/apply는
backend 초기화 후에도 이 대조를 다시 수행하며, 다르면 정리 대상으로 인정하지 않는다.

| 확인 지점 | 진행 방법 |
|---|---|
| EKS 생성·공개 인프라·DNS | `--execute infra` / `public-infra` / `dns`로 기존 operate의 **새 plan** 작성. 출력된 경로의 plan.log를 비공개로 검토한 뒤 같은 단계에 `--review-dir 경로 --confirm 확인값` 추가. 기존 1시간·코드/설정/주체 검증·plan 재사용 금지를 유지 |
| data SG·dev 비밀 복사 | 안내한 기존 Terraform 절차를 직접 실행. 복사는 EC2 SSM에서 `scripts/ec2/copy_eks_dev_secrets.py copy`를 사용. DB/SG 교체 없는 plan 확인·apply는 사람이 담당. 복사 스위치는 false로 되돌리고 적용 |
| Argo CD·root·비밀 앱·prod DB·복사·LBC | 첫 미완료 단계에 `--execute 단계`와 기존 `--confirm-cluster` 또는 `--confirm-env`를 명시하면 **해당 단계 하나만** 실행. 기존 도구의 검사·승인 인자를 그대로 전달 |
| Rollouts·ESO·초기 admin 비밀 | 기존 앱 등록·사람 Sync. 초기 비밀을 키체인에 저장 후 초기 Secret 삭제. 도구는 컨트롤러/CRD 준비와 Secret 부재 확인 |
| prod 서비스·공개 Ingress·prod 정책 | 사람이 Argo CD에서 Sync. auth 카나리도 확인·승격. 도구가 Sync·Health와 pause 상태를 확인한 뒤 진행 |
| ALB CIDR | `--execute alb-policy --confirm-cluster ureka-eks`. ALB SG/WAF 검증 후 서브넷을 안전한 JSON 입력으로 조회. 기존 값이 같으면 주입 생략, 다르거나 중복이면 중단. JSON Patch test로 동시 중복 추가 차단 |
| 공개 open 전환 | 지원하지 않음. testers 유지. 공개 게이트·파트장 승인 후 별도 절차 |
| 연결 수 | PM과 정한 `UREKA_DB_CONNECTION_LIMIT` 필요. 최근 5분 DatabaseConnections Maximum이 없거나 상한 초과면 완료하지 않음 |
| 삭제 | Ingress 앱·리소스 없음 → 클러스터 태그 ALB 0 → root/업무 앱·Pod/LB/PVC 정리 → data 외부 SG 참조 없음 → `--execute destroy --confirm-cleanup ureka-eks`로 새 삭제 plan. 검토 후 경로·해시·동일 cleanup 확인을 붙여 apply |
| 잔존 | EKS 출력/클러스터 없음, Terraform EKS 태그 자원·알려진 WAF 부재 검사. 태그 없는 NAT/EIP/ENI/EBS·컨트롤러 자원·인증서·DNS는 운영 문서로 직접 조사한 뒤 `--confirm-residue ureka-eks`. 태그 조회만으로 전체 정리를 보증하지 않음 |

Terraform plan은 생성·적용 양쪽에서 실제 변경 목록과 아래 범위를 검사한다.
허용한 EKS managed 주소 목록은 `lifecycle.py`에 고정하며, 알 수 없는 자원·모듈의 변경은 거절한다.
기존 operate의 최신 main·plan 해시·주체·1시간·재사용 방지·cleanup 검사는 그대로 수행한다.

| plan 단계 | 허용 설정·변경 |
|---|---|
| infra | testers, public/DNS 모두 false. EKS·노드·애드온·ESO 역할과 EKS 전용 NAT/라우트 등 기본 인프라 주소만 생성/변경 |
| public-infra | testers, public=true·DNS=false. 인증서·검증 CNAME·시험자 SG·WAF·LBC IAM 주소만 생성/변경 |
| dns | testers, public/DNS=true. `aws_route53_record.public` 별칭 레코드만 생성/변경. plan/apply 직전 target healthy 재검사 |
| destroy | 알려진 EKS 기본·공개·DNS 주소만 삭제. 기존 open 규칙도 삭제할 수 있으나 생성/변경은 허용하지 않음 |

각 lifecycle plan의 `review.json`에 단계를 기록하고 이를 포함해 확인 해시를 다시 계산한다.
다른 단계나 기존 standalone operate에서 만든 plan은 받아들이지 않으므로 해당 lifecycle 단계에서
새 plan을 만들어 검토한다. 생성 단계의 open 전환은 허용하지 않는다. 초기 infra 생성 전에 이전
공개/DNS 설정을 false·testers로 정리한다. public-infra는 DNS=false로 적용하고, 이후 정책·targets
검증을 마친 기록이 있을 때만 DNS=true 상태로 재개할 수 있다(앞 단계의 실제 상태 검사도 유지).

예를 들어 첫 미완료 단계가 prod DB라면:

```sh
python3 scripts/eks/lifecycle.py up --execute prod-db --confirm-env prod
```

기존 도구가 preflight로 요구하는 prod 네임스페이스가 먼저 필요하므로 root 등록과
restricted 네임스페이스 확인을 prod DB보다 앞에 둔다. dev는 비밀 준비 중 일시적으로
미준비일 수 있다. prod 서비스 Sync는 DB·ExternalSecret 준비 뒤 사람이 실행한다.
LBC 등록 후 Sync나 ALB 파라미터 주입 뒤 정책 Sync가 아직이면 해당 단계에서 다시 멈추며,
이미 등록된 내용을 덮어쓰지 않는다.

상태는 `.local/eks/up-<서울 날짜>/state.json` 또는 `down-<날짜>/state.json`에
시작/종료 시각·단계 결과·시도별 초를 기록한다(폴더 0700, 파일 0600).
같은 날짜의 재실행은 같은 기록을 사용한다. 다음 날 이어 갈 때는 최초 `--run-id YYYYMMDD`를
지정한다. 의도적으로 새 실행을 시작하려면 `--run-id YYYYMMDD-HHMMSS`를 쓴다.
같은 로컬 저장소의 Git common dir 아래 `ureka-lifecycle-locks/`(0700)에
계정·서울 리전·클러스터를 해시한 대상 잠금 파일(0600)을 두어, 다른 worktree·방향의
동시 실행도 차단한다. 기존 worktree 내부 상태 잠금도 유지한다. 종료 시 OS가 잠금을
해제하므로 남은 파일만 보고 잠금을 강제로 지우지 않는다. 다른 PC나 lifecycle을 거치지
않고 직접 실행하는 기존 도구/수동 작업까지 보호하지는 못한다.
대상 계정·context와 클러스터 생성 시점은 해시로만 묶고 원문은 저장하지 않는다.
실패는 `failed`, 사람 대기는 `waiting`, 재확인 완료는 `skipped`로 남는다.
표는 작업 합계(사람 대기 제외)와 전체 경과(사람 대기 포함)를 구분한다.

DB 부트스트랩·복사는 기존 도구가 실제 Job 성공과 임시 자원 정리까지 확인한 경우에만
성공 증빙 해시를 저장한다. 단순 `check` 성공을 DB 완료로 취급하지 않는다.
재개 시 대상 클러스터·data 출력·prod 비밀 변경 시점이 달라지면 증빙을 인정하지 않는다.
이 도구 밖에서 이미 채운 prod 데이터를 메타데이터만으로 완료 처리하지 않는다.
기존 데이터가 있는 재생성에서는 다음처럼 기존 복사 도구의 `verify` 모드로 실제 대조한다.

```sh
python3 scripts/eks/lifecycle.py up --execute content --verify-existing --confirm-env prod
```

이 모드는 동일 공유 Lease·임시 자원 정리 경로를 사용한다. Flyway/기준 표·FK·활성 임베딩
규칙, 집계, 복사 대상 전체 행 내용과 소유 시퀀스를 비교하며 prod 영구 데이터에 COPY/DDL을
수행하지 않는다. 임시 표를 준비한 뒤 prod 조회는 하나의 READ ONLY 스냅샷으로 실행한다.
성공하면 현재 대상에 대한 증빙을 만들고 이후 재개에서 건너뛴다. 빈 대상이나 차이가 있으면
멈추며 자동 복사로 전환하지 않는다. 실제 데이터에서는 대조 비용과 지연을 별도 측정한다.
DB 부트스트랩은 새 클러스터에서 기존 도구의 멱등 apply로 계정/DB 상태를 다시 확인할 수 있다.
기존 데이터 재복사나 상태 파일 편집으로 강제 통과하지 않는다.

새 실행기는 하위 명령의 원본 stdout/stderr를 화면·상태·별도 로그로 복사하지 않는다.
기존 도구가 원래 만드는 Terraform review/plan/apply 로그는 계속 비공개 운영 자료이며
민감값을 포함할 수 있다. `.local/` 전체를 공유·커밋하지 않는다. 새 상태에는 입력값,
IP, 계정 ID, 비밀, 원본 오류를 넣지 않는다. 실패 시 공개 채팅에 원본 오류를 붙이지 않는다.

단위 시험과 로컬 실제 CLI의 `--help` 검사만으로 AWS API 호환성이나 기동/삭제 성공을
증명할 수 없다. WAF 설명 문자나 AWS CLI 입력 파일처럼 mock이 놓치는 문제가 남을 수 있다.
실제 읽기 전용 AWS smoke는 운영자가 호출을 승인한 뒤에만 아래처럼 별도 실행한다.
이번 구현 단계에서는 AWS·클러스터 호출 금지에 따라 실행하지 않는다.

```sh
UREKA_RUN_AWS_READONLY_SMOKE=1 python3 -m unittest discover -s tests/eks -p test_lifecycle.py -v
```

실환경 최초 재생성 때 plan/apply·DB·ALB/WAF·DNS·잔존과 시간을 직접 검증한다.
검증 전이므로 이 문서에는 실제 켜기·끄기 소요 숫자를 적지 않는다.
