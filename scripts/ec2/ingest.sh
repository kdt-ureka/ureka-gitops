#!/usr/bin/env bash
# ingest 최초 적재를 EC2 dev에서 사람이 직접 돌린다(Argo CD 자동 sync 아님). EC2 서버 안(SSM 셸)에서 root로 실행한다.
#
#   sudo bash scripts/ec2/ingest.sh prepare          PVC 2개·NetworkPolicy·도구 ConfigMap·파일 Pod(ingest-files) 만들기
#   sudo bash scripts/ec2/ingest.sh recv             내 PC → EC2 원본 CSV 받기(127.0.0.1:18090, SSM 포트 포워딩으로만). 세 파일 받으면 끝
#   sudo bash scripts/ec2/ingest.sh store            받은 CSV를 ingest-input PVC로 옮기고 sha256 대조, 같으면 서버 사본 삭제
#   sudo bash scripts/ec2/ingest.sh stat             PVC의 CSV 3개 바이트·sha256·행 수
#   sudo bash scripts/ec2/ingest.sh run sample [N]   시험 적재: 공통 CSV 앞쪽 movie N/2·tv N/2개 content_id만(기본 100, 1시간 제한)
#   sudo bash scripts/ec2/ingest.sh run full         전체 적재(14시간 제한). OTT 최종화까지 ingest가 한다
#   sudo bash scripts/ec2/ingest.sh progress [Job]  적재 중 DB 건수·격리 줄 수·Pod 자원(가장 최근 Job 기본)
#   sudo bash scripts/ec2/ingest.sh quarantine [Job] 격리 요약(단계·오류 코드별)
#   sudo bash scripts/ec2/ingest.sh report           적재 결과 건수(작품·검색문서·임베딩 비율·OTT·검색 가능·실행 기록). 잠깐 Pod를 띄우고 지운다
#   sudo bash scripts/ec2/ingest.sh cleanup          파일 Pod만 지운다(PVC·Job 결과는 남긴다)
#
# 원본 CSV는 Git·채팅·문서에 올리지 않는다(위치·링크도). 비밀값은 Secret에서 환경 변수로만 들어가고 이 스크립트는 읽지 않는다.
# 시험 run(--content-id)은 OTT full snapshot이 아니라서 현재 OTT 상태를 바꾸지 않는다. 검색 가능 작품 수는 전체 run 뒤에 본다.
{ set +x; } 2>/dev/null
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$root/environments/ec2/dev/ingest"
tools="$root/scripts/ec2/ingest"
registry_env="${UREKA_ETC_DIR:-/etc/ureka}/registry.env"
upload_dir="${UREKA_INGEST_UPLOAD_DIR:-/var/lib/ureka-ingest-upload}"
port=18090
ns=dev
pod=ingest-files
names=(01_공통_common_staging_v0_0_21.csv 02_movie_details_staging_v0_0_21.csv 03_tv_series_details_staging_v0_0_21.csv)
kinds=(common movie tv)

[ "$(id -u)" = 0 ] || { echo "root로 실행하세요: sudo bash scripts/ec2/ingest.sh ..." >&2; exit 1; }
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="$PATH:/usr/local/bin" ;; esac
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { kubectl --context default -n "$ns" --request-timeout=30s "$@"; }
kx() { kubectl --context default -n "$ns" "$@"; } # 오래 걸리는 exec(파일 전송·sha256)용, 시간 제한 없음

registry() {
  [ -f "$registry_env" ] || { echo "${registry_env}이 없습니다. EC2 dev 서버에서 실행하세요." >&2; exit 1; }
  local r
  r="$(sed -n 's/^ECR_REGISTRY=//p' "$registry_env" | head -n1)"
  [[ "$r" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || { echo "ECR_REGISTRY 형식이 아닙니다(값은 출력하지 않음)." >&2; exit 1; }
  printf '%s' "$r"
}

# 템플릿 자리를 바꿔 표준 출력으로 낸다. 레지스트리 주소(계정 ID)는 화면에 내지 않는다(kubectl apply -f -로만 보낸다).
render() { # render <파일> <JOB_NAME> <DEADLINE> [content_id...]
  local file="$1" job="$2" deadline="$3"; shift 3
  ECR_REGISTRY="$(registry)" JOB="$job" DEADLINE="$deadline" python3 -I - "$file" "$@" <<'PY'
import os, re, sys
path, ids = sys.argv[1], sys.argv[2:]
uuid = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
if any(not uuid.match(i) for i in ids):
    sys.exit("content_id 형식이 아닌 값이 있습니다")
src = open(path, encoding="utf-8").read()
extra = "".join(f"            - --content-id\n            - {i}\n" for i in ids)
src = src.replace("            - __EXTRA_ARGS__\n", extra)
for key, value in (("__ECR_REGISTRY__", os.environ["ECR_REGISTRY"]), ("__JOB_NAME__", os.environ["JOB"]), ("__DEADLINE__", os.environ["DEADLINE"])):
    src = src.replace(key, value)
if "__" in re.sub(r"#.*", "", src):
    sys.exit("바꾸지 못한 자리가 남았습니다")
sys.stdout.write(src)
PY
}

need_pod() {
  [ "$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] \
    || { echo "파일 Pod($pod)가 Running이 아닙니다. 먼저: sudo bash scripts/ec2/ingest.sh prepare" >&2; exit 1; }
}
tool() { kx exec -i "$pod" -- python /tools/csvtool.py "$@"; }

check_job() { [[ "$1" =~ ^ingest-load-(sample|full)-[0-9]{12}$ ]] || { echo "Job 이름 형식이 아닙니다: ingest-load-sample|full-YYYYMMDDHHMM" >&2; exit 2; }; }
latest_job() {
  k get jobs -l app.kubernetes.io/name=ingest-load --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | tail -n1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  prepare)
    k apply -f "$dir/storage.yaml"
    k apply -f "$dir/networkpolicy.yaml"
    k create configmap ingest-tools --from-file=csvtool.py="$tools/csvtool.py" --dry-run=client -o yaml | k apply -f -
    if k get pod "$pod" >/dev/null 2>&1; then
      echo "파일 Pod가 이미 있습니다(도구를 바꿨으면 cleanup 뒤 다시 prepare)."
    else
      render "$dir/files-pod.yaml" unused 0 | k apply -f -
    fi
    k wait --for=condition=Ready "pod/$pod" --timeout=180s
    k get pvc ingest-input ingest-output
    echo "준비 완료. 다음: recv(내 PC에서 보내기) → store"
    ;;
  recv)
    command -v python3 >/dev/null || { echo "python3가 필요합니다" >&2; exit 1; }
    echo "내 PC 순서: ① 새 탭에서 SSM 포트 포워딩(로컬 ${port} → 서버 ${port}) ② 다른 탭에서 curl -T 세 번(docs/ec2-ingest.md)"
    python3 -I "$tools/recv.py" "$upload_dir" "$port"
    ;;
  store)
    need_pod
    ok=1
    for i in 0 1 2; do
      f="$upload_dir/${names[$i]}"
      [ -f "$f" ] || { echo "없음: ${names[$i]} (먼저 recv)" >&2; ok=0; continue; }
      host_sha="$(sha256sum "$f" | cut -d' ' -f1)"
      info="$(kx exec -i "$pod" -- python /tools/csvtool.py put "${kinds[$i]}" < "$f")"
      pod_sha="$(printf '%s' "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
      if [ "$host_sha" = "$pod_sha" ]; then echo "같음  $info"; else echo "다름  ${names[$i]} 서버 $host_sha / PVC $pod_sha" >&2; ok=0; fi
    done
    if [ "$ok" = 1 ]; then
      rm -f -- "${upload_dir:?}"/*.csv
      echo "세 파일 모두 sha256이 같습니다. 서버 임시 사본을 지웠습니다(PVC에만 남음)."
      echo "내 PC의 sha256·행 수와도 맞춰 보세요(docs/ec2-ingest.md)."
    else
      echo "일치하지 않거나 빠진 파일이 있습니다. 서버 사본은 지우지 않았습니다." >&2; exit 1
    fi
    ;;
  stat)
    need_pod; tool stat
    ;;
  run)
    mode="${1:-}"; n="${2:-100}"
    case "$mode" in
      sample) deadline=3600 ;;
      full) deadline=50400 ;;
      *) echo "사용법: run sample [N] | run full" >&2; exit 2 ;;
    esac
    need_pod
    active="$(k get jobs -l app.kubernetes.io/name=ingest-load -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{"\n"}{end}')"
    [ -z "$active" ] || { echo "이미 실행 중인 적재 Job이 있습니다: $active" >&2; exit 1; }
    for s in ureka-ingest-db ureka-chat-ai; do
      k get secret "$s" >/dev/null 2>&1 || { echo "Secret $s가 없습니다(값은 보지 않음)." >&2; exit 1; }
    done
    tool stat >/dev/null || { echo "PVC에 CSV 3개가 없습니다. store를 먼저 하세요." >&2; exit 1; }
    job="ingest-load-$mode-$(date -u +%Y%m%d%H%M)"
    ids=""
    if [ "$mode" = sample ]; then
      ids="$(tool pick "$n")"
      echo "시험 대상 $(printf '%s\n' "$ids" | grep -c .)개(movie $((n / 2)), tv $((n / 2)))"
    fi
    # content_id(UUID, 공백 없음)를 줄 단위로 인자로 넘긴다. render가 UUID 형식을 다시 검사한다.
    # shellcheck disable=SC2086
    render "$dir/job.yaml" "$job" "$deadline" $ids | k apply -f -
    echo "만듦: $job (제한 ${deadline}초). 진행: sudo bash scripts/ec2/ingest.sh progress $job"
    ;;
  progress)
    job="${1:-$(latest_job)}"
    [ -n "$job" ] || { echo "적재 Job이 없습니다." >&2; exit 1; }
    check_job "$job"
    k get job "$job" -o jsonpath='{.metadata.name} 시작 {.status.startTime} 끝 {.status.completionTime} 실행 {.status.active} 성공 {.status.succeeded} 실패 {.status.failed}{"\n"}'
    p="$(k get pods -l "job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$p" ] && [ "$(k get pod "$p" -o jsonpath='{.status.phase}')" = Running ]; then
      k top pod "$p" --containers 2>/dev/null || true
      # Job Pod 안에서 ingest 계정으로 건수만 센다(ingest 계정의 SELECT 권한 범위, 값은 출력하지 않음).
      kx exec "$p" -- python -c '
import os, psycopg
q = {
 "작품": "SELECT count(*) FROM catalog.contents",
 "검색문서 completed": "SELECT count(*) FROM rag.content_search_documents WHERE generation_status = '"'"'completed'"'"'",
 "활성 임베딩": "SELECT count(*) FROM rag.content_embeddings WHERE is_active",
 "검색 가능 작품": "SELECT count(*) FROM catalog.contents WHERE is_searchable",
}
with psycopg.connect(os.environ["CONTENT_DB_DSN"]) as c:
    for name, sql in q.items():
        print(f"{name}: {c.execute(sql).fetchone()[0]}")
' || echo "DB 건수 조회 실패(적재에는 영향 없음)" >&2
    fi
    if [ "$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; then
      kx exec "$pod" -- sh -c "test -f /output/$job/quarantine.jsonl && wc -l < /output/$job/quarantine.jsonl | sed 's/^/격리 줄 수: /' || echo '격리 파일 아직 없음'"
    fi
    k logs "job/$job" --tail=3 2>/dev/null || true
    ;;
  quarantine)
    need_pod
    job="${1:-$(latest_job)}"
    check_job "$job"
    tool quarantine "$job"
    ;;
  report)
    k delete pod ingest-report --ignore-not-found --wait=true >/dev/null
    render "$dir/report-pod.yaml" unused 0 | k apply -f - >/dev/null
    for _ in $(seq 60); do
      phase="$(k get pod ingest-report -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in Succeeded|Failed) break ;; esac
      sleep 2
    done
    k logs ingest-report 2>&1 || true
    [ "${phase:-}" = Succeeded ] || echo "확인 Pod가 끝나지 않았거나 실패했습니다(상태: ${phase:-없음})." >&2
    k delete pod ingest-report --ignore-not-found --wait=false >/dev/null
    [ "${phase:-}" = Succeeded ]
    ;;
  cleanup)
    k delete pod "$pod" --ignore-not-found --wait=true
    echo "파일 Pod를 지웠습니다. PVC(ingest-input·ingest-output)와 Job 기록은 남아 있습니다."
    ;;
  *)
    sed -n '2,14p' "$0" >&2; exit 2
    ;;
esac
