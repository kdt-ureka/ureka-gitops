# kind dev 배포·롤백 절차

kind dev는 Argo CD가 이 저장소 `main`을 보고 자동으로 맞춘다(auto-sync, prune, selfHeal). 그래서 **배포도 롤백도 Git PR로만 한다.** 클러스터에서 `kubectl edit`·`helm upgrade`로 바꾸면 selfHeal이 Git 상태로 되돌린다.

| 무엇 | 어디 |
|---|---|
| 서비스별 이미지(tag + digest)·설정 | `environments/kind/ureka-<서비스>.yaml` |
| Application(무엇을 어디에 배포할지) | `argocd/kind/` (현재 recommend, dev 네임스페이스) |
| dev 네임스페이스(Pod Security restricted) | `environments/kind/namespace/dev.yaml` |

## 배포 (새 이미지)

1. 서비스 저장소 main 병합 → CI가 ECR에 `sha-<커밋>` 이미지를 게시하고 artifact `image-ref.json`에 digest를 남긴다.
2. 이미지를 kind 로컬 레지스트리로 복사한다(조회 전용 SSO 프로필, README 1장).

   ```bash
   scripts/kind/sync-ecr-image.sh <서비스> <커밋 SHA 40자>
   ```

   출력 digest = `image-ref.json` digest인지 확인한다. 다르면 멈춘다.
3. 이 저장소에서 브랜치를 만들고 values의 `tag`·`digest` **두 줄만** 바꾼다.

   ```yaml
   image:
     repository: localhost:5001/ureka/<서비스>
     tag: sha-<새 커밋>
     digest: sha256:<image-ref.json의 digest>
   ```

4. `scripts/check-charts.sh` 통과 → PR(본문에 CI 실행 링크와 digest) → 승인 1명 → Squash 병합.
5. Argo CD가 main 변경을 감지해 동기화한다. kind는 GitHub webhook을 받을 수 없어 폴링(기본 3분 주기)만 쓴다. 2026-11-09 확인에서 push 후 반영까지 1분 53초~6분 14초(한 번은 리비전 캐시 때문에 한 주기를 놓쳤다). 시연처럼 바로 봐야 하면 아래 refresh를 친다.

   ```bash
   kubectl -n argocd annotate app ureka-<서비스>-kind argocd.argoproj.io/refresh=normal --overwrite
   kubectl -n argocd get app ureka-<서비스>-kind   # Synced / Healthy
   kubectl -n dev get deploy ureka-<서비스> -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

## 롤백

**원칙: 이전에 정상이던 값으로 되돌리는 PR을 만든다.** Argo CD UI의 Rollback 버튼은 auto-sync를 켠 Application에서는 쓸 수 없고, 써도 Git과 어긋나 selfHeal이 다시 덮는다. Git이 기준이다.

1. 장애 확인: `kubectl -n argocd get app ureka-<서비스>-kind`가 `Degraded`/`Progressing`에 머물거나, 새 Pod가 Ready가 되지 않는다. 이전 ReplicaSet Pod가 남아 있으면 서비스는 계속된다(RollingUpdate 기본값: 새 Pod가 Ready가 돼야 이전 Pod를 내린다).
2. 되돌릴 커밋을 찾는다.

   ```bash
   git log --oneline -- environments/kind/ureka-<서비스>.yaml
   ```

3. revert 브랜치 → PR → 승인 → 병합.

   ```bash
   git switch -c fix/<이슈>-rollback-<서비스> origin/main
   git revert <배포 PR의 squash 커밋>
   scripts/check-charts.sh
   git push -u origin HEAD   # PR 본문: 장애 내용, 되돌리는 digest(이전 정상값), 확인 방법
   ```

   revert 대신 values에서 `tag`·`digest`를 이전 정상값으로 직접 고쳐도 된다. 이전 digest는 `git log -p`나 이전 배포 PR 본문에서 찾는다. 이전 이미지가 로컬 레지스트리에 없으면(클러스터·레지스트리를 다시 만든 경우) `sync-ecr-image.sh`로 다시 복사한다.
4. 병합 후 refresh → `Synced / Healthy`, 이미지가 이전 digest인지 확인한다(배포 5번 명령).

급할 때: 승인 대기 중에도 장애가 계속되면 CN 팀장이 판단한다. 클러스터를 손으로 고치지 않는다(selfHeal이 되돌리고, Git 기록이 남지 않는다).

## 검증 기록

### 2026-11-09 (PR kdt-ureka/ureka-gitops#4, 검증 동안 Application이 PR 브랜치를 봄)

kind v0.32.0, Kubernetes v1.36.1, Argo CD v3.6.0, arm64 노드(ECR 이미지는 amd64, Docker Desktop Rosetta로 실행). 대상 recommend `sha-1593061` (digest = CI image-ref.json). 수동 refresh 없이 폴링만으로 측정.

| 단계 | Git 변경 | 결과 | push → 반영 |
|---|---|---|---|
| 배포 | replicas 1 → 2 | 2/2 Ready, Synced/Healthy | 1분 53초 |
| selfHeal | (클러스터에서 `kubectl scale --replicas=5`) | 2개로 복귀 | 2초 |
| 장애 릴리스 | `MOCK_MODE=false` (readyz 503) | 새 Pod 0/1, 이전 Pod 2개가 계속 응답, Synced/Progressing | 3분 3초 |
| 롤백 | 장애 커밋 `git revert` | Synced/Healthy, 장애 ReplicaSet 0, 이전 Pod 재시작 없음 | 2분 54초 |
| 정리 | replicas 2 커밋 `git revert` | 1/1 | 6분 14초 |

이번 롤백은 **설정 롤백**이다. 실제 ECR 이미지는 서비스마다 아직 digest가 하나뿐이라(문서 커밋은 같은 이미지로 빌드됨) **이전 digest로 되돌리는 롤백은 새 digest가 생긴 뒤 같은 절차로 다시 기록한다.**

### 2026-11-09 main 기준 (이슈 kdt-ureka/ureka-gitops#9)

PR #4 병합 후 Application을 `targetRevision: main`으로 다시 적용(`kubectl apply -f argocd/kind/`). 수동 refresh 없이 폴링만으로 측정.

| 단계 | PR | main 병합 | Argo CD 반영 | 결과 |
|---|---|---|---|---|
| 배포 | #10 replicas 1 → 2 | 03:07:40Z | 03:09:15Z (1분 35초) | 2/2 Ready 03:09:22Z, Synced/Healthy |
| 롤백 | 이 PR, #10 `git revert` | | | 병합 후 측정해 #9에 기록 |
