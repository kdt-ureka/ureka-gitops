# EC2 관측 설치·검증 절차

설계 기준: 비공개 ureka-docs `architecture/03-jvm-memory-observability-plan.md` 및 docs#44.
이 문서는 배포 설정의 실행 안내이며 설치 성공 보고가 아니다. **준혁·규진·현우 공동 진행**, EC2 접속/설치는 CN 권한으로만 한다. 팀원 ReadOnlyAccess로 실행하는 명령이 아니다.

## 준비와 변경 순서

1. 준혁님이 EC2를 켜고 SSM으로 접속한다. EC2 안에서 `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, context `default`를 명시한다. 개인 PC의 다른 프로젝트 context에서 실행하지 않는다.
2. `kubectl top node`, `kubectl top pods -A --containers`, `kubectl describe node`로 기존 사용량·스케줄링 request·MemoryPressure·디스크를 기록한다. Grafana/Prometheus/상태 수집기 request 합계 1Gi, limit 1.75Gi, PVC 6Gi의 초기 제안을 검토한다.
3. auth#29·content#42: 준혁님 관측/보호 리뷰 → 서비스 담당 기존 업무·인증 유지 확인 → 병합 → CI 이미지 digest 확보. `environments/ec2/dev/ureka-{auth,content}.yaml`의 이미지 변경 PR에 **새 digest**를 넣는다. 기존 이미지에 관측 포트를 먼저 켜지 않는다.
4. 도구 이미지 버전과 index digest는 `environments/ec2/observability/values.yaml`에 고정했다. 공유 설치 전에 이미지 취약점 검사를 검토하고 필요하면 승인된 digest로 바꾼다. 이번 작성 환경에서는 Trivy 검사를 실행하지 않았다.
5. `appMetrics.enabled`, `appMetrics.chatEnabled`, `argocd/ec2/apps/values.yaml`의 `jvmMetricsEnabled`는 모두 false다. 첫 PR 병합만으로 앱 설정이나 공유 환경 설치를 켜지 않는다. chat은 기존 업무 토큰이 아닌 전용 수집 자격 지원·승인 이미지를 담당자와 먼저 확인한다.

## 공동 설치

다음은 EC2 안 CN 셸에서 승인된 Git 커밋을 받은 뒤 실행한다.

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl --context default get nodes
kubectl --context default apply -f environments/ec2/observability/namespace/observability.yaml
sudo python3 scripts/ec2/prepare-observability-secrets.py
```

이 단계는 Grafana 자격만 만든다. 기존 Secret을 덮어쓰지 않고 출력하지 않는다. 비밀번호는 운영자만 Secret에서 확인하며 로그/채팅/PR에 붙이지 않는다. namespace는 restricted다.

승인된 서비스 이미지가 배포되고 규진님의 네트워크 검토가 준비되면:

```sh
sudo python3 scripts/ec2/prepare-observability-secrets.py --app-metrics
```

`dev`의 `ureka-auth-metrics`·`ureka-content-metrics` Secret(`METRICS_SCRAPE_TOKEN` 키)을 별도로 생성하고, 같은 수집 값만 `observability/ureka-metrics-tokens`의 auth/content 키로 전달한다. 업무용 `INTERNAL_SERVICE_TOKEN`을 복사하지 않는다. 기존 수집 Secret은 보존하고 업무 값과 동일·서비스 간 중복·빈 값·관측 측 불일치면 덮어쓰지 않고 중단한다. 스크립트는 값이 명령 인자/출력에 남지 않도록 메모리와 stdin만 쓴다.

앱 차트는 관측을 켤 때만 서비스별 전용 Secret에서 `METRICS_SCRAPE_TOKEN`을 주입한다. 회전은 앱과 수집 측을 함께 계획하고, 변경 후 앱 재기동·Prometheus 파일 갱신·거부/성공·up 회복을 확인한다. Prometheus에는 Secret 읽기 RBAC가 없다.

chat은 전용 수집 자격 지원을 확인하기 전 `appMetrics.chatEnabled=false`를 유지한다. job과 chat 토큰 파일 자체를 마운트하지 않아, 기존 업무 토큰이 관측에 들어가지 않는다. 지원 이미지·앱 자격 연결·교차 자격 거부 시험을 확인한 뒤에만 `--app-metrics --chat-metrics`로 전용 chat Secret을 준비하고 별도 Git PR로 플래그를 켠다. 이 스크립트는 chat 앱의 전용 토큰 지원을 구현하지 않으며, 현재 chat 수집 성공으로 기록하지 않는다.

활성화도 **Git 변경 PR**로 진행하고 순서를 지킨다.

1. 승인된 서비스 이미지 digest가 배포됐지만 `jvmMetricsEnabled: false`인 상태에서 관측 `appMetrics.enabled: true`를 먼저 반영한다. Secret을 준비한 뒤 관측 앱을 수동 Sync해 9091 제한 정책부터 적용한다. 이때 앱 scrape의 일시적인 up=0은 포트 미활성 상태다.
2. 규진님과 정책 선택자·다른 허용 정책·기존 업무 통신을 확인한다. 그 다음 별도 Git 변경에서 `jvmMetricsEnabled: true`를 켜 JVM 관리 포트를 활성화한다. 초기 포트가 보호 없이 열리는 순서를 만들지 않는다.
3. Prometheus 수집 성공·잘못된 토큰 거부·업무 토큰의 지표 조회 거부·수집 토큰의 내부 업무 호출 거부·다른 Pod의 9091 연결 차단을 확인한다.

업무 Service는 계속 80→8080이며, JVM 컨테이너에 metrics:9091과 observability 프로필만 추가한다. root 앱의 기존 레지스트리 주입 값은 건드리지 않는다.

```sh
kubectl --context default apply -f argocd/ec2/observability-app.yaml
```

관측 Application에는 자동 sync/prune이 없다. 준혁님이 승인 커밋·변경 리소스를 확인한 뒤 Argo CD에서 수동 Sync한다. root 앱에는 관측 앱을 자동 등록하지 않는다. PVC는 삭제/정리 대상에서 보호한다.

## 연결 경계 확인

- kubelet HTTPS 10250 `/metrics/cadvisor`: Prometheus SA의 노드 목록 조회와 `nodes/metrics` GET, CA 검증. **nodes/proxy·cluster-admin·TLS 검증 끄기 없음**. 실제 k3s kubelet 인증서·webhook 인가를 확인한다. 401/403/CA 오류면 원인을 해결하고 진행한다.
- auth/content 9091: observability namespace **AND** obs-prometheus Pod만 허용. namespace와 Pod selector를 별도 from 항목(OR)으로 나누지 않는다.
- 이 정책은 dev 내부의 업무 포트 8080을 유지한다. 기존 API 호출·probe·가입/검색도 다시 확인한다. 전체 서비스 NetworkPolicy 설계/차단 시험 PR을 대체하지 않는다.
- 정책들은 합집합이다. 다른 넓은 ingress 허용이 9091을 다시 열지 않는지 규진님이 확인한다. Prometheus 쪽 egress 차단이 있다면 DNS·API server·kubelet·9091·chat8080·kube-state-metrics를 허용 목록과 함께 맞춘다.
- Prometheus/Grafana/상태 수집기는 ClusterIP만 제공한다. 관측 namespace에는 ingress 기본 차단, Grafana→Prometheus, Prometheus→상태 수집만 허용한다. 관리자 port-forward는 CN이 별도로 연다.

예시(EC2 안에서만 실행, 기본 localhost 바인딩):

```sh
kubectl --context default -n observability port-forward svc/obs-grafana 3000:3000
kubectl --context default -n observability port-forward svc/obs-prometheus 9090:9090
```

PC 연결은 준혁님이 관리하는 SSM 경로로 한다. `--address 0.0.0.0`, 공개 Ingress/NodePort, 보안 그룹 포트 개방을 추가하지 않는다.

## 실제 설치 때 남길 증거

- Argo Synced/Healthy, 세 도구 Pod Ready, PVC Bound, 재시작/OOM/MemoryPressure 없음.
- Targets에서 kubelet·kube-state-metrics·auth·content up=1, 예상 대상 개수. chat은 전용 자격 지원 후 별도 활성화하여 up=1을 확인한다. JVM Pod 교체 뒤 discovery가 새 Pod를 찾는지도 확인.
- Grafana에서 전 서비스 Pod CPU(cores)·working set(bytes)·재시작 및 JVM heap/nonheap/버퍼/스레드 그래프가 실제 요청 전후 갱신. ops/recommend는 Pod 지표만 포함하고 앱 계측은 후속.
- namespace/Pod 필터·수집 중단 시 데이터 단절·새 Pod와 이전 Pod 구분 확인.
- 토큰 없는/잘못된 요청과 업무 토큰의 지표 조회 401, 수집 토큰의 내부 업무 접근 401, Prometheus 정상 요청 성공, 다른 dev Pod/다른 observability Pod는 9091 연결 차단. 단순 YAML 존재를 차단 성공으로 기록하지 않는다.
- Grafana 익명 조회 거부. datasource·dashboard Git 복원, 재기동 후 데이터 유지, 3일/2GB 보관 옵션과 실제 디스크 상태 확인.
- Prometheus head series, 도구 Pod CPU/메모리, node 사용량을 평시/합의된 반복 작업에서 기록한다. 유료 Gemini 호출·k6 부하를 임의 실행하지 않는다.

## 지표의 한계와 알림

- working set은 RSS/heap/전체 네이티브와 다르다. nonheap은 힙 바깥 전체가 아니다. max=-1은 제외한다. 수집 중단을 0으로 채우지 않는다.
- chat DB 누계는 replica 간 합산하지 않는다(대시보드 max). HTTP 시간은 응답 시작까지이며 SSE 최종 완료 p95가 아니다. AI 누계는 provider 청구액이 아니다.
- 초기 3개 알림 규칙은 Prometheus에서 평가만 한다. 아직 수신 채널/Alertmanager/ops 자동 등록이 없다. 임계값과 점검 처리·누락 대상 감지는 설치 후 공동 조정한다.
- local-path PVC는 EC2 stop/start 때 유지되지만 노드/디스크 재생성 복구를 보장하지 않는다. PVC 삭제·자동 prune으로 종료하지 않는다. 로그/백업·SLO 보고서는 후속 작업이다.

## 오프라인 검증

`helm`, Python PyYAML 6.0.3, Prometheus 3.16.0 `promtool`로 실행한다.

```sh
PROMTOOL=/path/to/promtool bash scripts/check-observability.sh
```

렌더링/최소 RBAC/노출/자원 예산/기본 비활성/Secret 무출력·덮어쓰기 거절, Prometheus 설정·대시보드 PromQL·알림 지연을 검사한다. 실행 성공은 실제 EC2 scrape/TLS/NetworkPolicy/Grafana 검증을 대신하지 않는다.
