# EKS Argo CD 설치와 앱 연결 (#43)

현재 구현 범위는 **Argo CD 설치 도구**다. 앱 전체 동기화·Git 되돌리기 시험은 후속이며,
이 문서나 설치 성공만으로 #43 완료 처리하지 않는다.

## 순서

1. EKS 노드·기본 Pod Ready, 기존 RDS 가동·노드 SG 접근 허용 확인.
2. 아래 코드의 보안/교차 검토·PR·CI·리뷰·병합 후 설치 도구 check → 직접 install.
3. #63에서 기존 서비스 Secret 원본 보존과 Secrets Manager→ESO·최소 IRSA 권한을 준비.
4. EKS 전용 AppProject·root 앱·서비스 values·DB/Redis 연결·네임스페이스 정책을 검토.
5. 서비스별 마이그레이션·Ready·내부 호출을 확인한 뒤 전체 Git 동기화와 되돌리기를 시험.

기존 EC2와 RDS를 공유하므로 EKS에서 새 비밀번호를 생성하거나 기존 서비스 계정 암호를
덮어쓰지 않는다. `scripts/kind/create-secrets.sh`와 `scripts/ec2/rds-bootstrap.sh`는 EKS에서
그대로 실행하지 않는다. 키·비밀번호는 화면·로그·명령 인자·Git에 쓰지 않는다.

## 설치 전 확인 (내 PC, 변경 없음)

저장소 루트에서 실행한다. `UREKA_EXPECTED_ACCOUNT_ID`는 승인된 로컬 설정에서
읽어 준비한 값이며, 현재 로그인 계정을 무조건 승인 대상으로 삼지 않는다.

```sh
python3 scripts/eks/bootstrap_argocd.py check \
  --profile ureka-admin \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
```

로그인 계정·서울의 EKS ACTIVE·kubectl context의 서버 주소·Ready 노드 2대 이상을
확인한다. 공식 설치 파일을 다운로드해 기존 EC2와 같은 `v3.6.0` 및 SHA-256 고정값을
검증하고 `.local/eks/argocd-bootstrap`에 저장한다. 클러스터는 변경하지 않는다.

Argo CD 3.6은 Kubernetes 1.37을 시험한 버전이다.
[공식 호환 표](https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/).

## 설치 (내 PC, 실제 Kubernetes 변경)

```sh
python3 scripts/eks/bootstrap_argocd.py install \
  --profile ureka-admin \
  --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID" \
  --confirm-cluster ureka-eks
```

실행 관련 코드가 최신 main에 병합됐고 작업 폴더 변경이 없는지 확인한 뒤 위 검사를
반복한다. argocd 네임스페이스와 고정 공식 manifest를 server-side apply한다.
충돌 강제 덮어쓰기는 하지 않는다. 기존 owner와 충돌하면 멈춰 검토한다.
구성에는 CRD·ClusterRole/Binding·ServiceAccount·Deployment·StatefulSet 등 Argo CD가
클러스터를 관리할 권한이 포함되므로 단순 Pod 설치로 취급하지 않는다.

이번 단계의 argocd namespace는 baseline을 강제하고 restricted 경고/감사를 적용한다.
앱의 dev/prod restricted 정책과 구분한다. upstream 설치 manifest에 대한 제한 강화는 별도 검토한다.
SSO용 dex·notifications는 사용하지 않아 replicas=0으로 줄인다.
server·repo-server·application-controller 준비를 각각 최대 5분 기다린다.
화면에는 단계·30초 진행 안내만 표시하며, 원본은 `.local/eks/argocd-bootstrap/run-*/`
단계별 로그에 실시간 저장한다. 비공개 기록을 공유하지 않는다.

외부 Ingress·LoadBalancer·도메인은 만들지 않는다. 앱 Application도 만들지 않고,
서비스 Secret·RDS 사용자/암호·DB 스키마를 읽거나 변경하지 않는다.
설치 뒤 `kubectl --context ureka-eks -n argocd get pods`로 Ready를 별도 확인한다.

## 실패·중복 실행

로컬 `in-progress` 기록으로 같은 PC의 중복 실행을 막는다. 여러 PC 사이의 잠금은
아니므로 운영자는 동시에 설치하지 않는다. 실패 시 자원·실행 프로세스·단계별 로그를
확인하고 기존 기록을 보존한다. 이전 프로세스가 끝났고 재실행 계획을 검토한 뒤에만
`in-progress` 파일을 제거하고 재시도한다. 자동 롤백·삭제·강제 재시도는 없다.
매 실행 로그는 새 run 폴더에 보존되며, 성공 때만 실행 잠금 기록을 제거한다.

server-side apply가 필요한 이유는 CRD annotation 크기 제한이다.
[공식 설치 안내](https://argo-cd.readthedocs.io/en/stable/getting_started/).

## 아직 확인하지 않은 것

- 새 도구로 실제 EKS 설치·Pod Ready·기능 동작
- 이미지 취약점 재검사·실제 사용량·노드 여유
- EKS 앱·Secret 연결, 실제 DB 인증/TLS, Git 배포/되돌리기

로컬 시험과 설치 파일 checksum 일치는 위 실환경 확인을 대체하지 않는다.
