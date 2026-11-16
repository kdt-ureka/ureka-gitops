# EC2 dev (k3s) 운영

EC2 한 대에 k3s를 올린 팀 공유 dev 환경입니다(이슈 #32). 서버와 네트워크는 `infra/environments/{network,ec2}`(Terraform)가 만들고, 이 문서는 그 위에서 앱을 설치하고 운영하는 방법을 다룹니다. 공유 환경 담당이 넘겨받을 때 이 문서를 기준으로 삼습니다.

- 들어오는 포트가 없습니다. 접속은 SSM만 씁니다. 셸은 CN(관리자 권한)만 쓰고, 화면은 80번 포트 포워딩 문서로 봅니다.
- 이미지는 노드(kubelet)가 ECR에서 바로 받습니다. ECR 주소에는 계정 ID가 들어 있어 Git에 쓰지 않습니다. 첫 부팅 때 `/etc/ureka/registry.env`에 남기고, `up.sh`가 root 앱에 넣습니다.
- **첫 버전은 잃어도 되는 dev입니다.** DB·Secret·Argo CD가 모두 EC2 루트 디스크에 있습니다. 중지·시작해도 그대로 남지만, EC2를 **다시 만들면** 전부 사라집니다(아래 "다시 만들기").

아래 명령에서 "내 PC"는 `infra/environments/ec2` 폴더에서 실행합니다. 이 폴더에서 `terraform init`을 해 두고, `export AWS_PROFILE=ureka-admin`과 `aws sso login`을 마친 상태여야 합니다. "서버 안"은 SSM 셸(`sh-5.2$`)입니다.

## 구성

| 경로 | 내용 |
|---|---|
| `argocd/ec2/root-app.yaml` | root 앱. `up.sh`가 ECR 주소를 채워 등록합니다. 직접 `kubectl apply`하지 않습니다 |
| `argocd/ec2/apps/` | root 앱이 렌더링하는 차트. 앱을 네임스페이스(wave -2) → 데이터(-1) → 서비스 6개(0) 순서로 만듭니다 |
| `environments/base/` | 모든 환경에 공통인 values(env·probe·포트) |
| `environments/ec2/dev/` | EC2 dev에서만 다른 값(이미지 digest·메모리·Ingress), 네임스페이스, 데이터(첫 버전은 kind data 그대로) |
| `scripts/ec2/up.sh` | 서버 안에서 실행: Argo CD → 네임스페이스 → Secret → root 앱 |

## 켜기·끄기

평소 운영은 이것뿐입니다. 쓸 때 켜고, 다 쓰면 끕니다.

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
sudo dnf install -y git
git clone https://github.com/kdt-ureka/ureka-gitops.git && cd ureka-gitops
sudo bash scripts/ec2/up.sh
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

## CN 전용: Argo CD 화면·받은 메일

서버 안에서 서비스를 서버의 localhost로 열고, 내 PC에서 일반 포트 포워딩으로 연결합니다. 관리자 권한이 필요하며, 팀원 권한 세트에는 없습니다.

```bash
# 서버 안: Argo CD(8443) 또는 Mailpit(8025)
sudo k3s kubectl -n argocd port-forward svc/argocd-server 8443:443
sudo k3s kubectl -n dev port-forward deploy/mailpit 8025:8025
```

```bash
# 내 PC (Mailpit이면 8443 대신 8025)
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=8443,localPortNumber=8443
```

Argo CD 초기 비밀번호는 서버 안에서만 확인합니다(채팅·문서에 붙이지 않습니다).

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

처음 로그인한 뒤 화면의 User Info → Update Password에서 비밀번호를 바꿉니다. 그다음 초기 비밀번호 Secret을 지웁니다(`sudo k3s kubectl -n argocd delete secret argocd-initial-admin-secret`). 바꾼 비밀번호는 팀 비밀번호 관리 도구에만 둡니다.

## 비밀값 다시 넣기

Secret은 `create-secrets.sh`가 이 서버에서 만들고, 이미 있으면 절대 덮어쓰지 않습니다. 그래서 값을 바꾸려면 **지우고 다시 만듭니다.** 값은 출력하지 않습니다.

| 상황 | 할 일 (서버 안, `ureka-gitops` 폴더) |
|---|---|
| chat AI 키 바꾸기·끄기 | `sudo k3s kubectl -n dev delete secret ureka-chat-ai`. 바꿀 때만 다시 `sudo bash scripts/ec2/up.sh --chat-ai`를 실행합니다. 그다음 `sudo k3s kubectl -n dev rollout restart deployment/ureka-chat deployment/ureka-chat-worker` |
| chat·ops 묶음(`db-accounts-chat-ops`·`ureka-chat-secrets`·`ureka-ops-secrets`)이 일부만 남아 `up.sh`가 멈춤 | 이 묶음만 다시 만듭니다. DB는 그대로 둡니다. 아래 "chat·ops 묶음 다시 만들기" |
| 기본 묶음(`postgres-admin`·`db-accounts`·`ureka-auth-secrets` 등 6개)이 일부만 남음, 또는 전부 새로(유출이 의심될 때 등) | **EC2 다시 만들기**로 합니다(아래 절). DB·Secret이 모두 사라집니다 |

chat·ops 묶음 다시 만들기(서버 안):

```bash
sudo k3s kubectl -n dev delete secret db-accounts-chat-ops ureka-chat-secrets ureka-ops-secrets --ignore-not-found
sudo bash scripts/ec2/up.sh
# 새 비밀번호를 DB 계정에 반영(db-bootstrap은 data 앱이 동기화될 때 PostSync로 돈다).
# 끝난 이전 Job을 먼저 지워야 아래 wait가 이전 Job을 보고 바로 성공하지 않는다.
sudo k3s kubectl -n dev delete job db-bootstrap --ignore-not-found
sudo k3s kubectl -n argocd patch app ureka-dev-data-ec2-dev --type merge -p '{"operation":{"sync":{}}}'
sudo k3s kubectl -n dev wait --for=create job/db-bootstrap --timeout=300s
sudo k3s kubectl -n dev wait --for=condition=complete job/db-bootstrap --timeout=600s
# Pod는 시작할 때만 env를 읽는다
sudo k3s kubectl -n dev rollout restart deployment/ureka-chat deployment/ureka-chat-worker deployment/ureka-ops
```

기본 묶음은 클러스터 안에서 다시 만들지 않습니다. PostgreSQL 슈퍼유저 비밀번호가 DB를 처음 만들 때만 쓰여서 DB 볼륨까지 같이 지워야 합니다. 그런데 Argo CD 자동 동기화가 켜져 있으면, 지우는 도중에 postgres·PVC가 다시 만들어지는 경합이 생깁니다. 이 절차(자동 동기화 멈춤 → DB 사용 앱 중지 → 볼륨 삭제 확인 → 새 Secret → data 동기화·db-bootstrap 확인 → 재기동 → 자동 동기화 복구)는 아직 검증하지 않았습니다. 그래서 첫 버전에서는 EC2 다시 만들기만 안내합니다. 지금 DB는 잃어도 되는 dev 데이터입니다. RDS로 옮기면 이 절차가 바뀝니다(RDS PR).

## 다시 만들기 (EC2 교체)

다음 경우에만 EC2를 다시 만듭니다: 디스크가 망가졌을 때, k3s·첫 부팅 설정을 바꿨을 때, AMI를 새로 받을 때. 평소에는 중지·시작만 합니다.

- 새 AMI·user data가 나와도 서버가 저절로 교체되지 않습니다(`ignore_changes = [ami, user_data]`). 교체는 승인을 받은 뒤 `-replace`로만 합니다.
- 다시 만들면 루트 디스크가 같이 지워집니다. **DB·Secret·Argo CD가 모두 사라지고, 이미지도 새로 받습니다.** 팀에 미리 알립니다.
- 종료 보호가 켜져 있어서 그대로는 지울 수 없습니다. 승인을 받은 뒤 지금 서버의 종료 보호만 끄고 교체합니다. 새 서버는 Terraform 설정대로 종료 보호가 켜진 채 만들어집니다.

```bash
# 내 PC, infra/environments/ec2
terraform plan -replace=module.k3s_host.aws_instance.host -out tfplan
#  → plan(1 to add, 1 to destroy, 교체 대상이 이 인스턴스뿐인지)을 보안 교차 검토 + CN 리드 승인
aws ec2 modify-instance-attribute --instance-id "$(terraform output -raw instance_id)" --no-disable-api-termination
terraform apply tfplan
```

그다음 "처음 설치"를 처음부터 다시 합니다. 새 서버의 `/etc/ureka/registry.env`는 첫 부팅이 다시 만듭니다. apply 순서와 승인 규칙은 `infra/README.md`의 "실행 순서"를 따릅니다.

## 비용·예산 알림

서울 온디맨드 대략값입니다(이슈 #32, Pricing Calculator로 다시 확인).

| 항목 | 과금되는 때 | 대략 |
|---|---|---|
| t3.large | 켜 둔 시간만 | 시간당 $0.104 (업무 시간만 쓰면 월 약 $23) |
| 공인 IPv4 | 켜 둔 시간만 | 시간당 $0.005 |
| CPU 크레딧 초과분 | 켜 둔 동안 평균 CPU가 기준(t3.large 30%)을 넘을 때 | 쓴 만큼(`unlimited`) |
| 루트 EBS gp3 40GB | **꺼도** 과금 | 월 약 $3.6 (하루 약 $0.1) |
| RDS (11/18~) | 켜 둔 동안 | 별도 PR에서 정함 |

- 예산 알림: 월 $100, Ureka 계정 범위로 걸려 있습니다. 실제 사용 50%·80%·100%와 예측 100%에 메일을 보냅니다(11/15 설정).
- 알림이 오면 위 "끄기 확인" 세 줄로 켜 둔 것이 없는지부터 봅니다. 그다음 Cost Explorer에서 서비스별 비용을 확인합니다.
- 메모리가 부족해 t3.xlarge로 올리면 시간당 비용이 두 배가 됩니다(중지 → `instance_type` 변경 → apply → 시작).

## 다음에 바뀌는 것

- RDS PR(11/18~): `environments/ec2/dev/data`에서 PostgreSQL을 빼고 DB 주소를 RDS로 바꿉니다. 비밀값 다시 넣기 절차도 바뀝니다.
- 팀원 공개 PR: NetworkPolicy와 팀원 권한 세트(80번 문서만)를 같이 넣습니다. 팀원용 접속 안내는 "화면 보기"와 "로컬 포트가 겹칠 때"만 따로 뽑습니다.
- 비밀값을 Secrets Manager → ESO로 옮기면, 다시 만들어도 비밀값이 사라지지 않습니다.
- 환경이 둘 이상이 되면(prod·EKS): env 중 일반 값은 환경별 ConfigMap(map, 키 단위 덮어쓰기)으로, 비밀값 참조는 base로 나눕니다.
