# EC2 dev (k3s) 설치와 접속

EC2 한 대에 k3s를 올린 팀 공유 dev 환경입니다(이슈 #32). 서버와 네트워크는 `infra/environments/{network,ec2}`(Terraform)가 만들고, 이 문서는 그 위에 앱을 올리는 순서를 다룹니다.

- 들어오는 포트가 없습니다. 접속은 SSM만 씁니다: 셸은 CN만 쓰고, 화면은 80번 포트 포워딩 문서로 봅니다.
- 이미지는 노드(kubelet)가 ECR에서 바로 받습니다. ECR 주소에는 계정 ID가 들어 있어 Git에 쓰지 않습니다. 첫 부팅 때 `/etc/ureka/registry.env`에 남기고, `up.sh`가 root 앱에 넣습니다.
- 첫 버전은 잃어도 되는 dev입니다. DB·Secret이 EC2 루트 디스크에 있어서, EC2를 **다시 만들면** 전부 사라집니다. 그래서 평소에는 중지·시작만 하고, 교체 plan은 승인 없이 apply하지 않습니다.

## 구성

| 경로 | 내용 |
|---|---|
| `argocd/ec2/root-app.yaml` | root 앱. `up.sh`가 ECR 주소를 채워 등록합니다. 직접 `kubectl apply`하지 않습니다 |
| `argocd/ec2/apps/` | root 앱이 렌더링하는 차트. 앱을 네임스페이스(wave -2) → 데이터(-1) → 서비스 6개(0) 순서로 만듭니다 |
| `environments/base/` | 모든 환경에 공통인 values(env·probe·포트) |
| `environments/ec2/dev/` | EC2 dev에서만 다른 값(이미지 digest·메모리·Ingress), 네임스페이스, 데이터(첫 버전은 kind data 그대로) |
| `scripts/ec2/up.sh` | 서버 안에서 실행: Argo CD → 네임스페이스 → Secret → root 앱 |

## 처음 설치 (CN, 한 번)

내 PC:

```bash
aws sso login --profile ureka-admin
cd infra/environments/ec2 && export AWS_PROFILE=ureka-admin
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
aws ec2 wait instance-status-ok --instance-ids "$(terraform output -raw instance_id)"
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

서버 안(`sh-5.2$`):

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

`Waiting for connections...`가 보이면 http://localhost:8080 에 접속합니다. Traefik이 frontend로 넘기고, frontend nginx가 `/api/*`를 각 서비스로 넘깁니다.

- 이 로컬 포트를 다른 프로그램(예: kind의 `kubectl port-forward`)이 이미 쓰고 있으면 `Starting session`에서 멈춥니다. 그럴 때는 다른 포트(예: `localPortNumber=18080`)를 씁니다.

## CN 전용: Argo CD 화면·받은 메일

서버 안에서 서비스를 서버의 localhost로 열고, 내 PC에서 일반 포트 포워딩으로 연결합니다(관리자 권한이 필요합니다. 팀원 권한 세트에는 없습니다).

```bash
# 서버 안: Argo CD(8443) 또는 Mailpit(8025)
sudo k3s kubectl -n argocd port-forward svc/argocd-server 8443:443
sudo k3s kubectl -n dev port-forward deploy/mailpit 8025:8025
```

```bash
# 내 PC
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=8443,localPortNumber=8443
```

Argo CD 초기 비밀번호는 서버 안에서만 확인합니다(채팅·문서에 붙이지 않습니다).

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 끝낼 때

```bash
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
```

중지하는 동안에는 루트 EBS만 과금됩니다. k3s·Argo CD·Secret·DB는 디스크에 남아서 다시 시작하면 그대로 뜹니다.

## 다음에 바뀌는 것

- RDS PR(11/18~): `environments/ec2/dev/data`에서 PostgreSQL을 빼고, DB 주소를 RDS로 바꿉니다.
- 팀원 공개 PR: NetworkPolicy와 팀원 권한 세트(80번 문서만)를 같이 넣습니다.
- 환경이 둘 이상이 되면(prod·EKS): env 중 일반 값은 환경별 ConfigMap(map, 키 단위 덮어쓰기)으로, 비밀값 참조는 base로 나눕니다.
