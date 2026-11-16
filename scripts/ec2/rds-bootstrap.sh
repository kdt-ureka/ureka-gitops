#!/usr/bin/env bash
# RDS에 서비스 DB·계정·vector 확장을 만든다(EC2 dev). 여러 번 실행해도 같은 상태가 된다.
# EC2 서버 안(SSM 셸)에서 root로 실행한다: sudo bash scripts/ec2/rds-bootstrap.sh
#
# 순서: 실행 잠금 → 이전 Job 종료 확인 → 마스터 비밀 읽기(Secrets Manager) → 임시 Secret rds-master
#       → Job db-bootstrap-rds(RDS 엔드포인트에 바로 접속) → 완료 대기 → 정리.
# 정리(성공·실패·Ctrl+C·시간 초과 모두): 끝나지 않은 Job·Pod를 지우고 없어졌는지 확인, rds-master를 지우고 없어졌는지 확인.
#   정리에 실패하면 경고하고 실패로 끝난다(비밀값은 출력하지 않음). 그때는 docs/ec2-dev.md 'RDS'의 잔존 확인을 따른다.
#   한계: SIGKILL·호스트 종료·k3s API 불통이면 이 스크립트가 정리할 수 없다. 다음 실행이 시작할 때 남은 것을 먼저 지운다.
# EC2 역할은 이 비밀 1개에만 GetSecretValue 권한이 있다(infra/environments/data).
#
# 처음 한 번 표준 입력으로 받아 /etc/ureka/rds.env(0640)에 둔다(다음부터는 묻지 않음):
#   마스터 비밀 ARN  내 PC: terraform -chdir=infra/environments/data output -raw master_secret_arn | pbcopy  (계정 ID 포함: 화면에 보이지 않게 입력)
#   RDS 엔드포인트    내 PC: terraform -chdir=infra/environments/data output -raw endpoint
# 비밀번호·ARN은 화면·명령 인자에 싣지 않는다(aws CLI에는 0600 입력 파일 경로만, kubectl은 --from-file).
{ set +x; } 2>/dev/null
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# 경로·대기 시간은 시험(scripts/test-rds-bootstrap.sh)에서만 바꾼다.
etc_dir="${UREKA_ETC_DIR:-/etc/ureka}"
rds_env="$etc_dir/rds.env"
registry_env="$etc_dir/registry.env"
lock_file="${UREKA_LOCK_FILE:-/run/lock/ureka-rds-bootstrap.lock}"
max_wait="${RDS_BOOTSTRAP_WAIT_SECONDS:-600}"
ns=dev
job=db-bootstrap-rds
req=(--request-timeout=20s)

[ "$(id -u)" = 0 ] || { echo "root로 실행하세요: sudo bash scripts/ec2/rds-bootstrap.sh" >&2; exit 1; }
# k3s가 설치한 kubectl(/usr/local/bin). sudo의 PATH에 없을 수 있어 없을 때만 뒤에 붙인다.
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="$PATH:/usr/local/bin" ;; esac
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { kubectl --context default -n "$ns" "${req[@]}" "$@"; }
for c in kubectl aws python3 flock; do
  command -v "$c" >/dev/null || { echo "$c가 필요합니다(AL2023: sudo dnf install -y awscli-2 util-linux)" >&2; exit 1; }
done

# 한 번에 하나만 실행한다(두 실행이 서로의 Secret·Job을 지우지 않게).
install -d -m 0755 "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { echo "다른 rds-bootstrap이 실행 중입니다. 끝난 뒤 다시 실행하세요." >&2; exit 1; }

[ -f "$registry_env" ] || { echo "${registry_env}이 없습니다. EC2 dev 서버에서 실행하세요." >&2; exit 1; }
region="$(sed -n 's/^AWS_REGION=//p' "$registry_env" | head -n1)"
[[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || { echo "${registry_env}의 AWS_REGION 형식이 아닙니다." >&2; exit 1; }

arn_re='^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:rds![A-Za-z0-9-]+$'
host_re='^[a-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws\.com$'
read_setting() { [ -f "$rds_env" ] && sed -n "s/^$1=//p" "$rds_env" | head -n1 || true; }
arn="$(read_setting RDS_MASTER_SECRET_ARN)"
host="$(read_setting RDS_ENDPOINT)"
if [ -z "$arn" ] || [ -z "$host" ]; then
  if [ -t 0 ]; then
    printf '마스터 비밀 ARN(입력은 화면에 보이지 않음): ' >&2; IFS= read -rs arn || true; echo >&2
    printf 'RDS 엔드포인트: ' >&2; IFS= read -r host || true
  else
    IFS= read -r arn || true; IFS= read -r host || true
  fi
  [[ "$arn" =~ $arn_re ]] || { echo "RDS 관리 비밀 ARN 형식이 아닙니다(값은 출력하지 않음)." >&2; exit 1; }
  [[ "$host" =~ $host_re ]] || { echo "RDS 엔드포인트 형식이 아닙니다." >&2; exit 1; }
  install -d -m 0750 "$etc_dir"
  ( umask 027; printf 'RDS_MASTER_SECRET_ARN=%s\nRDS_ENDPOINT=%s\n' "$arn" "$host" >"$rds_env" )
  echo "${rds_env}에 저장했습니다(다음부터는 묻지 않음)."
fi
[[ "$arn" =~ $arn_re ]] || { echo "${rds_env}의 ARN 형식이 아닙니다." >&2; exit 1; }
[[ "$host" =~ $host_re ]] || { echo "${rds_env}의 엔드포인트 형식이 아닙니다." >&2; exit 1; }

# 서비스 계정 해시 Secret이 있어야 한다(up.sh → create-secrets.sh가 만든다).
for s in db-accounts db-accounts-chat-ops; do
  k get secret "$s" -o name >/dev/null 2>&1 || { echo "Secret ${s}이 없습니다. 먼저 sudo bash scripts/ec2/up.sh" >&2; exit 1; }
done

work="$(mktemp -d)"
job_done=0   # 1이면 Job이 성공으로 끝나 Pod가 이미 종료됐다(로그 보존을 위해 Job은 ttl까지 남긴다)

gone() { # 종류 이름: 없으면 0
  local err
  if err="$(k get "$1" "$2" -o name 2>&1 >/dev/null)"; then return 1; fi
  printf '%s' "$err" | grep -q '(NotFound)'
}
delete_and_confirm() { # 종류 이름: 지우고 사라졌는지 확인(최대 3번)
  local i
  for i in 1 2 3; do
    k delete "$1" "$2" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
    if gone "$1" "$2"; then return 0; fi
    sleep $((i * 2))
  done
  return 1
}
cleanup() {
  local rc=$? failed=0
  trap - EXIT INT TERM
  rm -rf "$work"
  # 끝나지 않은 Job(실패·중단·시간 초과)은 Pod까지 지운다. Pod가 env로 읽은 마스터 비밀번호를 계속 들고 있지 않게.
  if [ "$job_done" != 1 ]; then
    delete_and_confirm job "$job" || { echo "경고: Job ${job}을(를) 지우지 못했습니다. sudo k3s kubectl -n ${ns} delete job ${job}" >&2; failed=1; }
    if ! k wait --for=delete pod -l "job-name=${job}" --timeout=60s >/dev/null 2>&1; then
      if [ -n "$(k get pod -l "job-name=${job}" -o name 2>/dev/null)" ]; then
        echo "경고: bootstrap Pod가 남아 있습니다. sudo k3s kubectl -n ${ns} delete pod -l job-name=${job}" >&2; failed=1
      fi
    fi
  fi
  delete_and_confirm secret rds-master || { echo "경고: 임시 Secret rds-master를 지우지 못했습니다(마스터 비밀번호 포함). sudo k3s kubectl -n ${ns} delete secret rds-master" >&2; failed=1; }
  if [ "$failed" = 1 ] && [ "$rc" = 0 ]; then rc=3; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 0) 이전 실행이 남긴 것(SIGKILL 등)을 먼저 지운다. Secret은 이전 Job·Pod가 사라진 뒤에만 새로 만든다.
delete_and_confirm job "$job" || { echo "이전 Job ${job}을(를) 지우지 못했습니다." >&2; exit 1; }
k wait --for=delete pod -l "job-name=${job}" --timeout=60s >/dev/null 2>&1 || true
[ -z "$(k get pod -l "job-name=${job}" -o name 2>/dev/null)" ] || { echo "이전 bootstrap Pod가 남아 있습니다." >&2; exit 1; }
delete_and_confirm secret rds-master || { echo "이전 Secret rds-master를 지우지 못했습니다." >&2; exit 1; }

# 1) 마스터 비밀(JSON: username, password) → 파일 두 개(권한 600). ARN은 입력 파일로만 넘기고, 오류 출력도 감춘다.
umask 077
python3 -I -c 'import json,sys; json.dump({"SecretId": sys.stdin.read().strip()}, open(sys.argv[1], "w"))' "$work/req.json" <<<"$arn"
if ! aws secretsmanager get-secret-value --region "$region" --cli-input-json "file://$work/req.json" \
    --query SecretString --output text >"$work/secret.json" 2>"$work/aws.err"; then
  echo "마스터 비밀을 읽지 못했습니다(권한·ARN·네트워크). 오류 원문에는 ARN이 있어 출력하지 않습니다." >&2
  grep -oE '\((AccessDenied[A-Za-z]*|ResourceNotFoundException|[A-Za-z]+Exception)\)' "$work/aws.err" | head -n1 >&2 || true
  exit 1
fi
python3 -I - "$work" <<'PY'
import json, os, sys
d = sys.argv[1]
with open(os.path.join(d, "secret.json")) as f:
    s = json.load(f)
u, p = s.get("username", ""), s.get("password", "")
if not u or not p:
    sys.exit("마스터 비밀에 username·password가 없습니다(값은 출력하지 않음)")
for name, val in (("PGUSER", u), ("PGPASSWORD", p)):
    with open(os.path.join(d, name), "w") as f:
        f.write(val)
for name in ("secret.json", "req.json"):
    os.remove(os.path.join(d, name))
PY

# 2) 임시 Secret. 값은 파일로만 간다.
k create secret generic rds-master --from-file=PGUSER="$work/PGUSER" --from-file=PGPASSWORD="$work/PGPASSWORD" >/dev/null
rm -f "$work/PGUSER" "$work/PGPASSWORD"

# 3) SQL·본문 ConfigMap(kind와 같은 파일)과 Job. PGHOST는 RDS 엔드포인트(ExternalName 전환 전에도 검증할 수 있게).
k create configmap db-bootstrap-rds \
  --from-file=db-bootstrap.sql="$root/environments/kind/data/db-bootstrap.sql" \
  --from-file=run-bootstrap.sh="$root/environments/kind/data/run-bootstrap.sh" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
RDS_HOST="$host" python3 -I -c '
import os, sys
src = open(sys.argv[1]).read()
old = "            - name: PGHOST\n              value: RDS_ENDPOINT\n"
if src.count(old) != 1:
    sys.exit("job.yaml의 PGHOST 자리를 찾지 못했습니다")
sys.stdout.write(src.replace(old, "            - name: PGHOST\n              value: %s\n" % os.environ["RDS_HOST"]))
' "$root/environments/ec2/dev/rds-bootstrap/job.yaml" | k apply -f - >/dev/null
echo "Job ${job} 실행 중(최대 10분)..."

# 4) 완료 또는 실패까지 기다린다.
result=""
for _ in $(seq 1 $((max_wait / 5))); do
  if [ "$(k get job "$job" -o 'jsonpath={.status.succeeded}' 2>/dev/null)" = 1 ]; then result=ok; break; fi
  if [ "$(k get job "$job" -o 'jsonpath={.status.failed}' 2>/dev/null)" = 1 ]; then result=failed; break; fi
  sleep 5
done
k logs "job/$job" --tail=20 2>/dev/null || true
case "$result" in
  ok) job_done=1; echo "db-bootstrap-rds 완료. 마스터 Secret을 지웁니다." ;;
  failed) echo "db-bootstrap-rds 실패. 위 로그를 확인하세요. Job과 마스터 Secret을 지웁니다." >&2; exit 1 ;;
  *) echo "10분 안에 끝나지 않았습니다. Job과 마스터 Secret을 지웁니다." >&2; exit 1 ;;
esac
cat <<'EOF'
다음(docs/ec2-dev.md 'RDS'): chat 마이그레이션 동기화 → 앱 재시작 → 확인.
EOF
