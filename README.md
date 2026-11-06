# ureka-gitops

Ureka AWS·EKS 인프라 및 Argo CD 배포 설정

## 구성

| 경로 | 내용 |
|---|---|
| `charts/ureka-backend/` | 백엔드(auth·chat·content·ops) 공통 Helm chart (Deployment, Service) |
| `environments/kind/` | kind(로컬) 환경 values. 서비스마다 파일 하나 |
| `argocd/kind/` | kind용 Argo CD Application |

## kind에서 실행 (ureka-auth 예시)

```bash
kind create cluster --name ureka
kubectl create namespace dev
# ureka-auth 저장소에서: docker build -t ureka-auth:local-<커밋> . && kind load docker-image ureka-auth:local-<커밋> --name ureka
helm install auth charts/ureka-backend -n dev -f environments/kind/ureka-auth.yaml
kubectl -n dev port-forward svc/ureka-auth 8081:80   # curl localhost:8081/healthz
```

이 저장소는 PUBLIC이다. 계정 ID, 비밀값, 토큰은 커밋하지 않는다.
