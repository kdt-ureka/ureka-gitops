# EKS 단기 가동 (#42)

이 문서는 CN 담당이 검토 후 실행할 절차다. 초안 작성 시 실제 AWS 조회·plan·apply·부팅 시간 측정은 하지 않았다.
일상적인 EKS plan·apply·상태·destroy는 저장소의 [공통 운영 도구](../scripts/eks/README.md)를 사용한다.
클러스터 생성 후 Argo CD는 [EKS 설치·앱 연결 절차](eks-argocd.md)를 따른다.
아래 Terraform 명령은 내부 동작 설명·문제 진단용이며, 공통 도구의 검토 절차를 생략하는 용도가 아니다.
network/data의 선후행 작업은 별도다. 운영 도구 추가 전 저장한 plan은 인계 근거로 보존하고,
도구 추가·리뷰·병합 뒤 새 plan을 만들어 검토한다.
`infra/environments/eks`는 기존 network를 태그로 찾고 private 노드와 NAT를 함께 생성/삭제한다. 외부 모듈 없이 AWS 리소스를 직접 작성해 IAM·보안 그룹·삭제 순서를 명시했다. provider는 기존 스택과 같은 `~> 6.69.0`, lock `6.69.1`이다.

## 설계와 비용

- EKS 1.37, 표준 지원만 사용. API는 private + CN 공인 IPv4 /32 제한 public. IP가 바뀌면 비공개 tfvars를 고치고 Terraform으로 API CIDR을 변경한다. CIDR 갱신은 Kubernetes API 접속을 요구하지 않는다.
- private AL2023 x86_64 t3.large on-demand 2대(min 2/max 3). 별도 autoscaler 없음. 3대는 `desired_nodes=3`으로 명시 변경한다. Spot은 재생성·멘토링 안정성을 위해 보류.
- EC2 단일 8Gi 호스트의 limit 합계 약 73%라는 인수인계 기록을 출발점으로 16Gi 총량을 선택했다. 실측 재확인 전이며 allocatable·DaemonSet 예약·동시 ingest·카나리·AZ별 PVC 배치를 감안해 실제 request/사용량을 확인한다. 2대가 Pod 분산이나 장애 시 용량을 보장하지는 않는다.
- 노드 공인 IP·SSH·SSM 없음. IMDSv2 필수, hop limit 1. hostNetwork Pod와 특권 Pod까지 IMDS가 차단되는 것은 아니므로 #62 Pod Security도 필요하다.
  #64 ALB 컨트롤러 설치 시 IMDS 조회 대신 `region`·`vpcId`를 명시한다.
- 노드 역할은 WorkerNodePolicy와 ECR PullOnly. WorkerNodePolicy에는 Pod Identity 관련 권한이 포함될 수 있지만 agent/association은 설치하지 않는다. CNI·EBS는 별도 IRSA 역할(정확한 SA sub와 STS aud). 앱 IAM·ESO·SQS는 #63에서 부여한다.
- CNI `enableNetworkPolicy=true`; 정책 자체와 EKS 차단 재시험은 #49. 기본 standard 시작 모드에서는 정책 적용 전 잠깐 허용될 수 있으므로 strict 모드는 DNS 허용 등 부팅 검증 뒤 #49에서 결정한다. 이 옵션만 켠 상태가 default-deny는 아니다.
- CoreDNS·kube-proxy·EBS CSI. CNI는 노드 전에, 나머지는 노드 후 설치한다. EBS CSI만으로 StorageClass/PVC가 만들어지지 않는다. #43 이후 `gp3` StorageClass(encrypted, WaitForFirstConsumer)와 관측 차트 설정을 별도로 준비한다. EBS는 AZ에 묶이므로 볼륨 복구·배치 시험 필요.
- audit만 CloudWatch 7일. Kubernetes audit에는 요청 메타데이터가 포함될 수 있다. 로그 접근 권한·수집량을 확인한다. 클러스터 삭제 보호 없음. 지원 종료 전 버전을 다시 검토한다.

다음은 서울·24시간·USD·세금 제외 **예산 추정**이다. 동적 리전 요율을 이번 작업에서 AWS API로 확인하지 않았다. CN이 계산기로 재확인한다.

| 구성 | 계산 | 하루 |
|---|---|---:|
| 표준 EKS | $0.10 × 24 | $2.40 |
| t3.large 2대 | 가정 $0.104 × 2 × 24 | $4.992 |
| NAT 1개 | 가정 $0.059 × 24 | $1.416 |
| NAT 공인 IPv4 1개 | $0.005 × 24 | $0.12 |
| 루트 gp3 20Gi × 2 | 가정 $0.0912/GiB월, 30일 환산 | $0.122 |
| 합계 | 데이터 처리·로그 등 제외 | **약 $9.05** |

3대는 약 $11.61/일. NAT 처리 가정 $0.059/GB, 다른 AZ→NAT 전송, 인터넷 전송, T3 CPU 크레딧, audit, 관측 PVC, RDS, 기존 EC2, ALB, LLM 비용 별도. NAT 1개는 첫 AZ 장애 시 두 AZ의 외부 연결이 끊기는 비용 절약안이다. 상시 운영 HA 설계가 아니다.
대안: public 노드는 IPv4 2대 $0.24/일로 NAT를 줄이지만 노드가 공인 주소를 갖는다. private 엔드포인트 5종(ECR api/dkr·EC2·STS·Logs)×2AZ는 시간당 $0.01~0.013 가정 시 $2.40~3.12/일+GB(S3 gateway 무료), 서비스별 추가가 필요하고 Gemini·TMDB는 별도 외부 경로가 필요하다.

출처: [EKS 버전](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html), [EKS 요금](https://aws.amazon.com/eks/pricing/), [VPC 요금](https://aws.amazon.com/vpc/pricing/), [PrivateLink 요금](https://aws.amazon.com/privatelink/pricing/), [EC2 요금](https://aws.amazon.com/ec2/pricing/on-demand/), [EBS 요금](https://aws.amazon.com/ebs/pricing/), [CNI 정책](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html), [IAM OIDC CA 검증](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html).

## 사전 검토·plan (CN 실행)

1. `network`와 기존 `data` 적용 상태를 확인한다. network private route table은 `route=[]`를 제거한 이번 코드로 먼저 plan한다. 로컬 교차 검토와 plan 검토 후 push·PR·리뷰·병합을 거쳐 CN이 직접 apply한다. EKS apply는 이 network 변경 적용 뒤 진행한다. route 속성을 생략하면 EKS가 만든 별도 NAT route를 network가 삭제하지 않는다. network는 NAT를 생성하지 않는다. NAT 기본 경로는 공유 private route table 전체(RDS 서브넷 포함)에 적용되며, RDS SG의 egress=[]와 비공개 설정은 유지한다. 기존 state의 inline 경로가 유지/삭제되는지는 network plan으로 반드시 확인한다.
2. 비공개 `backend.hcl`, `terraform.tfvars`를 예제에서 복사하고 로컬에서 실제 값으로 채운다. 다른 스택과 state key를 섞지 않는다. 계정 ID·ARN·IP·버킷 이름·plan·state는 Git/PR에 첨부하지 않는다.
3. SSO 역할의 **IAM role ARN**(SSO path 포함)을 `admin_role_arn`에 넣는다. STS session ARN은 안 된다. 실제 CN 역할인지 사람이 확인한다. 생성자 자동 관리자 권한은 꺼져 있다. SSO 역할 삭제/재생성 시 access entry도 재생성해야 한다.
4. CN이 아래 조회로 서울에서 1.37 및 애드온/AMI 호환성을 확인한 뒤 정확한 버전을 tfvars에 고정한다. 예제의 REPLACE 문자열은 고의로 validation에서 거부된다. mock 테스트의 버전은 합성 예제이며 가용성을 증명하지 않는다. CNI는 NetworkPolicy 보안 패치를 포함하는 버전(1.22.3 이상 여부)을 확인한다.

```sh
aws sso login --profile ureka-admin
aws eks describe-cluster-versions --region ap-northeast-2 --profile ureka-admin
aws eks describe-addon-versions --kubernetes-version 1.37 --region ap-northeast-2 --profile ureka-admin
aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.37/amazon-linux-2023/x86_64/standard/recommended/release_version --region ap-northeast-2 --profile ureka-admin
```

조회에서 버전이 제공되지 않으면 apply를 멈추고 버전·호환 핀·테스트를 함께 재검토한다. 추정값으로 바꾸지 않는다.

```sh
cd infra/environments/network
AWS_PROFILE=ureka-admin terraform init -backend-config=backend.hcl
AWS_PROFILE=ureka-admin terraform plan
# 여기서는 apply하지 않음. plan 검토 → push·PR·리뷰·병합 후 CN이 network apply
cd ../eks
AWS_PROFILE=ureka-admin terraform init -backend-config=backend.hcl
AWS_PROFILE=ureka-admin terraform plan -out=eks.tfplan
# 계획을 로컬에서 확인. 실값이 들어 있는 출력은 공개 게시하지 않는다.
```

plan 검토: subnet Tier/AZ, private route의 중복 소유권 없음, 관리자 CIDR/역할, 호환 버전, 노드 공인 IP 없음, NAT 1개, RDS 리소스 변경 없음, 삭제/교체 대상과 예상 비용. EKS 기본 cluster SG는 AWS가 관리하는 self ingress/egress가 있다. 노드에는 사용자 SG만 연결하며 control-plane→node 443/1025–65535, node→API 443 및 node 상호 통신만 수신한다. workload 경계는 #49에서 제한한다.

## 켜기 (검토 후 CN 실행)

1. 교차 검토·실제 plan 검토·PR 리뷰·병합을 마친 뒤 network 변경부터 CN이 직접 적용한다. 병합된 코드와 plan 작성 코드가 다르면 plan을 다시 작성·검토한다. 이어서 `eks`에서 검토한 `AWS_PROFILE=ureka-admin terraform apply eks.tfplan`. 완료 시 `terraform output kubeconfig_hint`의 명령으로 kubeconfig 갱신(로컬 비공개 파일).
2. 노드 2대 Ready, CNI/CSI/CoreDNS/kube-proxy 정상, private IP만 있는지 확인. 관리 API는 허용 /32 밖에서 차단되는지 확인한다.
3. `terraform output -raw node_security_group_id`를 **data의 비공개 tfvars** `eks_node_security_group_ids`에 한 개 넣는다. `data`에서 plan/apply한다. RDS SG description은 교체 방지를 위해 기존 문자열을 유지했다. 실제 허용 범위는 inline ingress가 정한다. RDS가 정지 중이면 CN이 별도 운영 절차로 켠다. SG 변경에 DB 교체가 없어야 한다.
4. 기존 EC2의 5432 규칙은 유지한다. 같은 RDS SG의 inline 규칙은 data가 단독 소유하며 EKS에는 외부 rule 리소스를 만들지 않는다. EKS VPC CNI Pod는 노드 SG를 사용한다. Security Groups for Pods로 전환 시 재검토한다.
5. #43 Argo CD 설치, #63 ESO/업무 IAM, StorageClass와 앱 설정을 연결한다. #49에서 기존 NetworkPolicy를 EKS VPC CNI 기준으로 재시험한다. 이 초안만으로 서비스가 배포되지는 않는다.

## 끄기 (검토 후 CN 실행)

1. 필요한 관측 데이터·DB를 백업/보존한다. EKS 재생성으로 local PVC 데이터는 복구되지 않는다.
2. Argo CD 자동 동기화/자원 재생성을 멈추고 앱·Ingress·LoadBalancer Service를 삭제한다. ALB/NLB·target group·컨트롤러가 만든 SG/ENI가 실제 제거될 때까지 컨트롤러를 살려 둔다. PVC는 백업·reclaimPolicy 확인 후 삭제, EBS 삭제/잔존을 확인한다.
3. data의 `eks_node_security_group_ids=[]`로 복원하고 **data만 plan/apply**해 외부 SG 참조를 먼저 제거한다. 생략하면 EKS node SG 삭제가 DependencyViolation으로 막힌다.
4. EKS에서 `AWS_PROFILE=ureka-admin terraform plan -destroy -out=eks-destroy.tfplan` 검토 후 `AWS_PROFILE=ureka-admin terraform apply eks-destroy.tfplan`. 애드온→노드→클러스터 순서와 함께 NAT/default route/EIP를 제거한다. network/data/shared는 destroy하지 않는다.
5. CN이 EKS·노드/ASG·NAT·EIP·EBS·ALB/ENI 잔존과 비용을 확인한다. kubeconfig의 옛 context를 로컬에서 제거한다. 별도 RDS/EC2는 해당 운영 절차로 중지한다. Terraform 밖 PVC/ALB와 retained EBS는 자동 삭제를 가정하지 않는다.

## 로컬 검증 (AWS 자격 불필요)

```sh
terraform -chdir=infra/environments/eks init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/environments/eks validate
terraform -chdir=infra/environments/eks test
terraform fmt -check -recursive infra
```

테스트의 `command=apply`는 `mock_provider` 메모리 내 실행이며 실제 apply가 아니다. network module/data 스택도 변경했으므로 각각 validate/test한다. CI matrix에 EKS를 추가했다.

## 시간 기록 (#67)

측정 전 추정치를 실측으로 쓰지 않는다. SSO·plan 대기와 실제 생성 시간을 구분한다.

| 단계 | 시작(KST) | 종료(KST) | 소요 | 결과·막힌 원인 |
|---|---|---|---|---|
| network 사전 변경 | 미측정 | 미측정 | 미측정 | |
| EKS apply→노드 Ready | 미측정 | 미측정 | 미측정 | |
| data SG 연결 | 미측정 | 미측정 | 미측정 | |
| #43 Argo CD→앱 Ready | 미측정 | 미측정 | 미측정 | |
| data SG 해제 | 미측정 | 미측정 | 미측정 | |
| EKS destroy→잔존 확인 | 미측정 | 미측정 | 미측정 | |
| 재생성→서비스 확인 | 미측정 | 미측정 | 미측정 | |

## 후속 범위

Argo CD #43, NetworkPolicy 재시험 #49, prod/RBAC/Pod Security #62, ESO·서비스 IRSA #63, ALB·도메인 #64, WAF #81, 자동 확장·HA NAT·S3 gateway 최적화는 이번 구현에 포함하지 않는다. 팀원 읽기 권한은 현재 부여하지 않았다.
