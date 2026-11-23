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

## 안전 시험

```sh
python3 -m unittest discover -s tests/eks -v
```

AWS 호출 없이 잘못된 계정·변경된 plan·미병합 코드·부분 실패 재실행·SG 참조 등 거부 경로를 검사한다.
실제 AWS 생성·삭제 검증은 별도다. 로컬 시험 통과를 실환경 검증으로 쓰지 않는다.

저장 plan 적용은 추가 Terraform 확인 질문 없이 실행되므로, `--confirm`에 검토 확인값을
입력하는 것을 명시 승인으로 사용한다. [Terraform apply 공식 문서](https://developer.hashicorp.com/terraform/cli/commands/apply).
