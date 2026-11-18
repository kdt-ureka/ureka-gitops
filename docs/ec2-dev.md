# EC2 dev (k3s) 운영

EC2 한 대에 k3s를 올린 팀 공유 dev 환경입니다(이슈 #32). 서버와 네트워크는 `infra/environments/{network,ec2}`(Terraform)가 만들고, 이 문서는 그 위에서 앱을 설치하고 운영하는 방법을 다룹니다. 공유 환경 담당이 넘겨받을 때 이 문서를 기준으로 삼습니다.

- 들어오는 포트가 없습니다. 접속은 SSM만 씁니다. 셸은 CN(관리자 권한)만 쓰고, 화면은 80번 포트 포워딩 문서로 봅니다.
- 이미지는 노드(kubelet)가 ECR에서 바로 받습니다. ECR 주소에는 계정 ID가 들어 있어 Git에 쓰지 않습니다. 첫 부팅 때 `/etc/ureka/registry.env`에 남기고, `up.sh`가 root 앱에 넣습니다.
- DB는 **RDS PostgreSQL**(`infra/environments/data`, 사설 서브넷, EC2에서만 5432)입니다. 앱 설정의 호스트 `postgres`가 RDS를 가리킵니다(아래 "RDS").
- Secret·Argo CD·Redis·Mailpit은 EC2 루트 디스크에 있습니다. 중지·시작해도 그대로 남지만, EC2를 **다시 만들면** 이것들은 사라집니다. DB(RDS)는 남습니다(아래 "다시 만들기").

아래 명령에서 "내 PC"는 `infra/environments/ec2` 폴더에서 실행합니다. 이 폴더에서 `terraform init`을 해 두고, `export AWS_PROFILE=ureka-admin`과 `aws sso login`을 마친 상태여야 합니다. "서버 안"은 SSM 셸(`sh-5.2$`)입니다.

## 구성

| 경로 | 내용 |
|---|---|
| `argocd/ec2/root-app.yaml` | root 앱. `up.sh`가 ECR 주소를 채워 등록합니다. 직접 `kubectl apply`하지 않습니다 |
| `argocd/ec2/apps/` | root 앱이 렌더링하는 차트. 앱을 네임스페이스(wave -2) → 데이터(-1) → 서비스 6개(0) 순서로 만듭니다 |
| `environments/base/` | 모든 환경에 공통인 values(env·probe·포트) |
| `environments/ec2/dev/` | EC2 dev에서만 다른 값(이미지 digest·메모리·Ingress), 네임스페이스, 데이터(kind data에서 PostgreSQL을 빼고 `postgres` → RDS ExternalName) |
| `environments/ec2/dev/rds-bootstrap/` | RDS에 서비스 DB·계정·vector를 만드는 Job. Argo CD가 관리하지 않고 아래 스크립트만 쓴다 |
| `scripts/ec2/up.sh` | 서버 안에서 실행: Argo CD → 네임스페이스 → Secret → root 앱 |
| `scripts/ec2/rds-bootstrap.sh` | 서버 안에서 실행: 마스터 비밀을 잠깐 읽어 bootstrap Job을 돌리고 지운다 |
| `infra/environments/data` | RDS(Terraform). 마스터 비밀번호는 RDS가 Secrets Manager에 관리한다 |

## 켜기·끄기

평소 운영은 이것뿐입니다. 쓸 때 켜고, 다 쓰면 끕니다. **EC2와 RDS는 따로 켜고 끕니다.** EC2를 꺼도 RDS가 켜져 있으면 계속 과금됩니다.

- 켤 때: RDS 먼저(몇 분) → EC2. 앱이 뜰 때 DB가 있어야 재시작이 적습니다.
- 끌 때: EC2 먼저 → RDS.
- 꺼 둔 RDS는 **7일이 지나면 AWS가 자동으로 다시 켭니다.** 오래 안 쓰면 일주일마다 다시 끕니다(예산 알림으로도 보인다).

```bash
# 내 PC: RDS 켜기·끄기·상태
aws rds start-db-instance --db-instance-identifier ureka-dev --query 'DBInstance.DBInstanceStatus' --output text
aws rds wait db-instance-available --db-instance-identifier ureka-dev && echo RDS READY
aws rds stop-db-instance --db-instance-identifier ureka-dev --query 'DBInstance.DBInstanceStatus' --output text
aws rds describe-db-instances --db-instance-identifier ureka-dev --query 'DBInstances[0].DBInstanceStatus' --output text
```

```bash
# 내 PC: 켜기 (1~2분 뒤 READY)
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)" --query 'StartingInstances[0].CurrentState.Name' --output text
aws ec2 wait instance-status-ok --instance-ids "$(terraform output -raw instance_id)" && echo READY
```

```bash
# 내 PC: 끄기
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)" --query 'StoppingInstances[0].CurrentState.Name' --output text
```

꺼졌는지 확인합니다. 세 줄의 기대값은 `stopped None` / `0` / `0`입니다(공인 IP 없음, 실행 중인 인스턴스 0, 남은 탄력적 IP 0).

```bash
aws ec2 describe-instances --instance-ids "$(terraform output -raw instance_id)" --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text
aws ec2 describe-addresses --query 'length(Addresses)' --output text
```

켠 뒤 k3s가 살아 있는지는 서버 안에서 확인합니다.

```bash
sudo systemctl is-active k3s; sudo k3s kubectl get node; sudo k3s kubectl -n argocd get applications
```

## 처음 설치 (CN, 한 번)

켜기를 마친 뒤 내 PC에서 셸에 접속합니다.

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

서버 안:

```bash
cd ~      # SSM 셸은 쓰기 권한 없는 폴더(/usr/bin 등)에서 시작한다. 그대로 clone하면 Permission denied
sudo dnf install -y git
git clone https://github.com/kdt-ureka/ureka-gitops.git && cd ureka-gitops
sudo bash scripts/ec2/up.sh
sudo bash scripts/ec2/rds-bootstrap.sh            # RDS에 서비스 DB·계정(처음엔 ARN·엔드포인트를 묻는다, 아래 "RDS")
sudo k3s kubectl -n argocd get applications      # 전부 Synced/Healthy까지 몇 분
sudo k3s kubectl -n dev get pods
```

- `up.sh`는 여러 번 실행해도 됩니다. 이미 있는 Secret은 바꾸지 않습니다.
- chat AI(팀 Gemini 키)는 선택입니다: `sudo bash scripts/ec2/up.sh --chat-ai`를 실행하고 키를 입력하면 됩니다. 입력은 화면에 보이지 않고, 키를 명령 인자·채팅·Git에 쓰지 않습니다. 실행이 끝나면 안내대로 chat을 재시작합니다.
- 이미지를 바꾸거나 되돌릴 때는 `environments/ec2/dev/ureka-<서비스>.yaml`의 tag·digest를 고치는 PR을 올립니다. main에 합쳐지면 Argo CD가 자동으로 배포합니다.

## 화면 보기 (80번 포트 포워딩)

내 PC:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name "$(terraform output -raw port_forward_document_name)" --parameters localPortNumber=8080
```

`Waiting for connections...`가 보이면 http://localhost:8080 에 접속합니다. Traefik이 frontend로 넘기고, frontend nginx가 `/api/*`를 각 서비스로 넘깁니다. 끝낼 때는 Ctrl+C를 누릅니다.

## 로컬 포트가 겹칠 때

내 PC의 같은 포트를 다른 프로그램(예: kind의 `kubectl port-forward`)이 이미 쓰고 있으면, 세션이 `Starting session with SessionId …`에서 더 진행되지 않습니다(`Waiting for connections`가 나오지 않음). 누가 쓰는지 확인하고, 그 프로그램을 끄거나 다른 로컬 포트를 씁니다.

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name "$(terraform output -raw port_forward_document_name)" --parameters localPortNumber=18080
```

80번 문서는 로컬 포트로 1024~65535만 받습니다. 다른 포트로 열었으면 화면 주소도 http://localhost:18080 처럼 바꿉니다.

아래 Mailpit(8025)·Argo CD(8443) 연결도 같습니다. kind Mailpit을 `kubectl port-forward`로 띄워 두었으면 내 PC의 8025가 겹치므로, 서버 쪽 포트(`portNumber`)는 그대로 두고 내 PC 쪽만 바꿉니다(예: `portNumber=8025,localPortNumber=18025` → http://localhost:18025).

## CN 전용: Argo CD 화면·받은 메일

서버 안에서 서비스를 서버의 localhost로 열고, 내 PC에서 일반 포트 포워딩으로 연결합니다. 관리자 권한이 필요하며, 팀원 권한 세트에는 없습니다.

```bash
# 서버 안: Argo CD(8443) 또는 Mailpit(8025)
sudo k3s kubectl -n argocd port-forward svc/argocd-server 8443:443
sudo k3s kubectl -n dev port-forward deploy/mailpit 8025:8025
```

```bash
# 내 PC (Mailpit이면 8443 대신 8025. 내 PC의 8025가 겹치면 localPortNumber만 18025로)
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=8443,localPortNumber=8443
```

Argo CD 초기 비밀번호는 서버 안에서만 확인합니다(채팅·문서에 붙이지 않습니다).

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

처음 로그인한 뒤 화면의 User Info → Update Password에서 비밀번호를 바꿉니다. 그다음 초기 비밀번호 Secret을 지웁니다(`sudo k3s kubectl -n argocd delete secret argocd-initial-admin-secret`). 바꾼 비밀번호는 팀 비밀번호 관리 도구에만 둡니다.

## RDS

| 항목 | 값 |
|---|---|
| 인스턴스 | `ureka-dev`, PostgreSQL 18(11/17 생성 시 18.3), db.t4g.micro, gp3 20GB 암호화, 단일 AZ(2a) |
| 접근 | 인터넷 공개 안 함, 사설 서브넷 2개. 인바운드는 EC2 보안 그룹에서 오는 5432뿐. TLS만 받는다(`rds.force_ssl=1`) |
| 보호 | 삭제 보호, 지울 때 최종 스냅샷, 자동 백업 1일 |
| 마스터 계정 | `ureka_admin`. 비밀번호는 RDS가 Secrets Manager에 관리한다(사람·Terraform state·Git에 원문 없음). 앱은 쓰지 않는다 |
| EC2 권한 | 그 비밀 1개에 `GetSecretValue`만 |

### 서비스 DB·계정 만들기 (`rds-bootstrap.sh`)

처음 설치, EC2 다시 만들기, 서비스 Secret을 새로 만든 뒤에 실행합니다. 여러 번 실행해도 결과가 같습니다.

순서: 실행 잠금 → 이전 Job·Pod·임시 Secret 정리 확인 → 마스터 비밀 읽기 → 임시 Secret `rds-master` → Job `db-bootstrap-rds`(RDS 엔드포인트에 TLS로 접속) → 끝나면 **성공·실패·중단 어느 경우든** 임시 Secret과 끝나지 않은 Job·Pod를 지웁니다. 지우지 못하면 경고하고 실패로 끝납니다.

처음 한 번은 마스터 비밀 ARN과 엔드포인트를 묻고 서버의 `/etc/ureka/rds.env`에 저장합니다. ARN에는 계정 ID가 있어 화면에 보이지 않게 입력합니다.

1. 서버 안: `sudo bash scripts/ec2/rds-bootstrap.sh`를 실행하고 ARN을 묻는 줄에서 기다린다.
2. 내 PC(새 탭이면 프로필부터): 아래로 ARN을 클립보드에 넣는다. 90~110자가 나와야 한다(빈 값이면 `0 chars`).

   ```bash
   export AWS_PROFILE=ureka-admin && set -o pipefail && terraform -chdir=infra/environments/data output -raw master_secret_arn | pbcopy && echo "copied $(pbpaste | wc -c | tr -d ' ') chars"
   ```

3. **그 사이에 다른 것을 복사하지 말고** 서버 탭에서 ⌘V → Enter. 이어서 엔드포인트(`terraform -chdir=infra/environments/data output -raw endpoint`)를 붙여 넣는다.

로그 끝에 확인 줄이 나옵니다(비밀값 없음).

```text
check vector 0.8.1 in catalog
check server 18.3, postgres db owner ureka_admin, public connect false
db-bootstrap 완료
```

끝난 뒤 임시 Secret이 없는지 확인합니다. 스크립트가 강제 종료(SIGKILL)되거나 서버가 꺼지면 스스로 정리하지 못하므로 그때도 이 두 줄로 확인하고 남았으면 지웁니다.

```bash
sudo k3s kubectl -n dev get secret rds-master                   # NotFound여야 한다
sudo k3s kubectl -n dev get pod -l job-name=db-bootstrap-rds    # Running이 없어야 한다
```

### vector 버전

RDS의 pgvector 버전은 엔진 마이너가 정합니다. 11/17 생성한 18.3은 **0.8.1**입니다(kind는 0.8.7). 엔진이 나중에 자동 마이너 업그레이드돼도 이미 설치된 확장은 저절로 올라가지 않습니다(`ALTER EXTENSION vector UPDATE`가 따로 필요). 어떤 기능까지 쓰는지는 AI팀과 맞춥니다.

### 처음 RDS로 옮기기 (한 번)

EC2 안 PostgreSQL에서 RDS로 바꿀 때 한 번만 합니다. 데이터는 옮기지 않습니다(EC2 안 DB는 시험용 데이터). 팀에 알리고 유지보수 시간에 합니다. 11/18 이 순서로 전환했습니다(#36).

1. RDS·EC2를 켜고 `rds-bootstrap.sh`로 RDS를 먼저 준비한다(위 확인 줄까지). 이때 앱은 아직 EC2 안 DB를 쓴다.
2. 전환 전 상태를 기준으로 남긴다(앱 9개 Synced/Healthy, `postgres` Service `ClusterIP`). 그다음 RDS 전환 PR을 병합한다. Argo CD가 EC2 안 postgres를 내리고 `postgres` Service를 RDS ExternalName으로 바꾼다. Argo CD는 3분마다 Git을 확인하므로, 바로 반영하려면 data 앱만 다시 읽게 한다.

   ```bash
   sudo k3s kubectl -n argocd annotate application ureka-dev-data-ec2-dev argocd.argoproj.io/refresh=hard --overwrite
   sudo k3s kubectl -n dev get svc postgres                                   # TYPE ExternalName, RDS 엔드포인트
   sudo k3s kubectl -n dev get statefulset,pod -l app.kubernetes.io/name=postgres   # No resources found
   ```
3. chat 마이그레이션(Alembic, PreSync)을 RDS에 돌린다.

   ```bash
   sudo k3s kubectl -n argocd patch app ureka-chat-ec2-dev --type merge -p '{"operation":{"sync":{}}}'
   sudo k3s kubectl -n dev get jobs ureka-chat-migrate      # Complete 1/1까지, AGE가 방금 생긴 값
   ```

   이 Job은 로그를 거의 남기지 않는다. 마이그레이션이 됐는지는 `Complete 1/1`과 5단계의 chat 응답으로 본다.

4. 앱을 다시 시작한다(auth·content·ops는 시작할 때 Flyway가 RDS에 스키마를 만든다).

   ```bash
   sudo k3s kubectl -n dev rollout restart deployment
   sudo k3s kubectl -n dev get pods
   ```

5. 화면에서 가입·로그인·채팅을 확인한다. RDS는 새 DB라 계정을 새로 만들고, Redis도 재시작돼 로그인 세션이 초기화된다. AI 키(`ureka-chat-ai`)가 없으면 페르소나 만들기(`POST /api/chat/v1/personas`)가 503으로 거절되는 것이 정상이다. 이때 목록 조회(`GET …/personas` 200)로 chat이 RDS를 읽는지 확인한다.

   ```bash
   sudo k3s kubectl -n dev logs deploy/ureka-frontend --since=15m | grep '/api/chat' | tail
   ```

6. 확인이 끝난 뒤에만 옛 DB 쪽을 지운다. 지우기 전에 대상을 본다(PVC는 `data-postgres-0` 하나, `Used By: <none>`).

   ```bash
   sudo k3s kubectl -n dev describe pvc data-postgres-0 | grep -E '^(Name|Status|Capacity|Used By)'
   # 옛 PostSync Job: Argo CD는 hook Job을 정리하지 않아 끝난 Job·Pod가 남는다. Job을 지우면 Pod도 지워진다.
   sudo k3s kubectl -n dev delete job db-bootstrap
   # 옛 DB 디스크(되돌릴 수 없음). k3s local-path는 PV와 실제 폴더도 같이 지운다.
   sudo k3s kubectl -n dev delete pvc data-postgres-0
   sudo k3s kubectl -n dev get pvc,job; sudo k3s kubectl get pv            # PVC·PV 없음, Job은 ureka-chat-migrate만
   ```

### RDS 지우기·다시 만들기

평소에는 하지 않습니다. 삭제 보호를 끄는 변경을 plan·교차 검토·승인 뒤 apply해야 지울 수 있고, 지울 때 최종 스냅샷(`ureka-dev-final`)이 남습니다. 이 이름은 고정이라 **두 번째로 지울 때는 이전 스냅샷과 이름이 겹쳐 실패합니다.** 그 전에 이전 스냅샷을 지우거나 `final_snapshot_identifier`를 새 이름으로 바꾸는 변경을 같이 넣습니다. 다시 만들면 엔드포인트가 바뀔 수 있어 `environments/ec2/dev/data`의 ExternalName도 고칩니다. 스냅샷에서 복원하는 절차는 아직 없습니다.

## 비밀값 다시 넣기

Secret은 `create-secrets.sh`가 이 서버에서 만들고, 이미 있으면 절대 덮어쓰지 않습니다. 그래서 값을 바꾸려면 **지우고 다시 만듭니다.** 값은 출력하지 않습니다.

| 상황 | 할 일 (서버 안, `ureka-gitops` 폴더) |
|---|---|
| chat AI 키 바꾸기·끄기 | `sudo k3s kubectl -n dev delete secret ureka-chat-ai`. 바꿀 때만 다시 `sudo bash scripts/ec2/up.sh --chat-ai`를 실행합니다. 그다음 `sudo k3s kubectl -n dev rollout restart deployment/ureka-chat deployment/ureka-chat-worker` |
| chat·ops 묶음(`db-accounts-chat-ops`·`ureka-chat-secrets`·`ureka-ops-secrets`)이 일부만 남아 `up.sh`가 멈춤 | 이 묶음만 다시 만듭니다. DB는 그대로 둡니다. 아래 "chat·ops 묶음 다시 만들기" |
| 기본 묶음(`postgres-admin`·`db-accounts`·`ureka-auth-secrets` 등 6개)이 일부만 남음, 또는 전부 새로(유출이 의심될 때 등) | **EC2 다시 만들기**로 합니다(아래 절). Secret은 새로 생기고 `rds-bootstrap.sh`가 RDS 계정 비밀번호를 새 값으로 바꿉니다. DB 데이터(RDS)는 남습니다 |

chat·ops 묶음 다시 만들기(서버 안). 무중단 교체가 아니므로 팀에 알리고 dev 유지보수 시간에 합니다. 명령이 하나라도 실패하면 거기서 멈추고 원인을 봅니다.

```bash
sudo k3s kubectl -n dev delete secret db-accounts-chat-ops ureka-chat-secrets ureka-ops-secrets --ignore-not-found
sudo bash scripts/ec2/up.sh
# 새 비밀번호를 RDS 계정에 반영(마스터 비밀은 실행하는 동안에만 쓰고 지운다)
sudo bash scripts/ec2/rds-bootstrap.sh
# Pod는 시작할 때만 env를 읽는다
sudo k3s kubectl -n dev rollout restart deployment/ureka-chat deployment/ureka-chat-worker deployment/ureka-ops
sudo k3s kubectl -n dev rollout status deployment/ureka-chat deployment/ureka-chat-worker deployment/ureka-ops --timeout=300s
```

끝나면 화면에서 로그인과 채팅이 되는지 확인합니다(DB 연결 확인).

기본 묶음을 클러스터 안에서 지우고 다시 만드는 절차는 아직 검증하지 않아 안내하지 않습니다(JWT 키가 바뀌어 모든 로그인이 끊기고, 서비스 Secret 10개를 한 번에 맞춰야 한다). EC2 다시 만들기로 합니다.

## 다시 만들기 (EC2 교체)

다음 경우에만 EC2를 다시 만듭니다: 디스크가 망가졌을 때, k3s·첫 부팅 설정을 바꿨을 때, AMI를 새로 받을 때, 기본 묶음 Secret이 깨졌거나 비밀값을 전부 새로 만들어야 할 때. 평소에는 중지·시작만 합니다.

- 새 AMI·user data가 나와도 서버가 저절로 교체되지 않습니다(`ignore_changes = [ami, user_data, associate_public_ip_address]`, 마지막은 꺼진 서버의 공인 IP 반납이 교체로 보이지 않게). 교체는 승인을 받은 뒤 `-replace`로만 합니다.
- 다시 만들면 루트 디스크가 같이 지워집니다. **Secret·Argo CD·Redis(로그인 세션)·Mailpit이 사라지고, 이미지도 새로 받습니다.** DB(RDS)는 남습니다. 팀에 미리 알립니다.
- 종료 보호가 켜져 있어서 그대로는 지울 수 없습니다. 승인을 받은 뒤 지금 서버의 종료 보호만 끄고 교체합니다. 새 서버는 Terraform 설정대로 종료 보호가 켜진 채 만들어집니다.

```bash
# 내 PC, infra/environments/ec2
terraform plan -replace=module.k3s_host.aws_instance.host -out tfplan
#  → plan(1 to add, 1 to destroy, 교체 대상이 이 인스턴스뿐인지)을 보안 교차 검토 + CN 리드 승인
aws ec2 modify-instance-attribute --instance-id "$(terraform output -raw instance_id)" --no-disable-api-termination
terraform apply tfplan
```

그다음 "처음 설치"를 처음부터 다시 합니다. 새 서버의 `/etc/ureka/registry.env`는 첫 부팅이 다시 만들고, `rds.env`는 `rds-bootstrap.sh`가 처음처럼 ARN·엔드포인트를 다시 묻습니다. 새 Secret의 비밀번호가 RDS 계정에 들어가고, RDS의 데이터는 그대로입니다. apply 순서와 승인 규칙은 `infra/README.md`의 "실행 순서"를 따릅니다.

## 비용·예산 알림

서울 온디맨드 대략값입니다(이슈 #32, Pricing Calculator로 다시 확인).

| 항목 | 과금되는 때 | 대략 |
|---|---|---|
| t3.large | 켜 둔 시간만 | 시간당 $0.104 (업무 시간만 쓰면 월 약 $23) |
| 공인 IPv4 | 켜 둔 시간만 | 시간당 $0.005 |
| CPU 크레딧 초과분 | 켜 둔 동안 평균 CPU가 기준(t3.large 30%)을 넘을 때 | 쓴 만큼(`unlimited`) |
| 루트 EBS gp3 40GB | **꺼도** 과금 | 월 약 $3.6 (하루 약 $0.1) |
| RDS db.t4g.micro | 켜 둔 시간만 | 시간당 약 $0.03 (대략, Calculator로 확인) |
| RDS gp3 20GB·자동 백업 | **꺼도** 과금(백업은 DB 크기까지 무료) | 월 약 $3 |
| Secrets Manager(RDS 마스터 비밀 1개) | 항상 | 월 약 $0.4 |

- 예산 알림: 월 $100, Ureka 계정 범위로 걸려 있습니다. 실제 사용 50%·80%·100%와 예측 100%에 메일을 보냅니다(11/15 설정).
- 알림이 오면 위 "끄기 확인" 세 줄과 RDS 상태로 켜 둔 것이 없는지부터 봅니다(꺼 둔 RDS가 7일 뒤 저절로 켜졌을 수 있다). 그다음 Cost Explorer에서 서비스별 비용을 확인합니다.
- 메모리가 부족해 t3.xlarge로 올리면 시간당 비용이 두 배가 됩니다(중지 → `instance_type` 변경 → apply → 시작).

## 다음에 바뀌는 것

- EKS(S8): EC2 아웃바운드 5432를 사설 서브넷 CIDR 대신 RDS 보안 그룹 참조로 줄이고, RDS 인바운드에 EKS 노드 보안 그룹을 더한다. TLS는 RDS CA 번들로 verify-full을 검토한다.
- 팀원 공개 PR: NetworkPolicy와 팀원 권한 세트(80번 문서만)를 같이 넣습니다. 팀원용 접속 안내는 "화면 보기"와 "로컬 포트가 겹칠 때"만 따로 뽑습니다.
- 비밀값을 Secrets Manager → ESO로 옮기면, 다시 만들어도 비밀값이 사라지지 않습니다.
- 환경이 둘 이상이 되면(prod·EKS): env 중 일반 값은 환경별 ConfigMap(map, 키 단위 덮어쓰기)으로, 비밀값 참조는 base로 나눕니다.
