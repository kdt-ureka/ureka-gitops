#!/usr/bin/env bash
# RDS에 서비스 DB·계정·vector 확장을 만든다(EC2 dev). 여러 번 실행해도 같은 상태가 된다.
# EC2 서버 안(SSM 셸)에서 root로 실행한다: sudo bash scripts/ec2/rds-bootstrap.sh
#
# 순서: 마스터 비밀 읽기(Secrets Manager) → 임시 Secret rds-master → Job db-bootstrap-rds → 완료 대기 → rds-master 삭제.
# 마스터 비밀번호는 실행하는 동안에만 클러스터에 있다. 성공·실패·중단 어느 경우든 끝날 때 Secret을 지운다.
# EC2 역할은 이 비밀 1개에만 GetSecretValue 권한이 있다(infra/environments/data).
#
# 마스터 비밀 ARN에는 계정 ID가 있어 Git에 쓰지 않는다. 처음 한 번 표준 입력으로 받아 /etc/ureka/rds.env(0640)에 둔다.
#   내 PC: terraform -chdir=infra/environments/data output -raw master_secret_arn | pbcopy
# 비밀번호·ARN은 화면·명령 인자에 싣지 않는다(aws CLI 결과는 표준 출력 → 파일, kubectl은 --from-file).
{ set +x; } 2>/dev/null
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
rds_env=/etc/ureka/rds.env
registry_env=/etc/ureka/registry.env
ns=dev
job=db-bootstrap-rds

[ "$(id -u)" = 0 ] || { echo "root로 실행하세요: sudo bash scripts/ec2/rds-bootstrap.sh" >&2; exit 1; }
export PATH="/usr/local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { kubectl --context default -n "$ns" "$@"; }
for c in kubectl aws python3; do
  command -v "$c" >/dev/null || { echo "$c가 필요합니다" >&2; exit 1; }
done
[ -f "$registry_env" ] || { echo "${registry_env}이 없습니다. EC2 dev 서버에서 실행하세요." >&2; exit 1; }
region="$(sed -n 's/^AWS_REGION=//p' "$registry_env" | head -n1)"
[[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || { echo "${registry_env}의 AWS_REGION 형식이 아닙니다." >&2; exit 1; }

arn_re='^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:rds![A-Za-z0-9-]+$'
arn=""
if [ -f "$rds_env" ]; then
  arn="$(sed -n 's/^RDS_MASTER_SECRET_ARN=//p' "$rds_env" | head -n1)"
fi
if [ -z "$arn" ]; then
  printf '마스터 비밀 ARN(terraform output -raw master_secret_arn): ' >&2
  IFS= read -r arn || true
  [[ "$arn" =~ $arn_re ]] || { echo "RDS 관리 비밀 ARN 형식이 아닙니다(값은 출력하지 않음)." >&2; exit 1; }
  install -d -m 0750 /etc/ureka
  ( umask 027; printf 'RDS_MASTER_SECRET_ARN=%s\n' "$arn" >"$rds_env" )
  echo "${rds_env}에 저장했습니다(다음부터는 묻지 않음)."
fi
[[ "$arn" =~ $arn_re ]] || { echo "${rds_env}의 ARN 형식이 아닙니다." >&2; exit 1; }

# 서비스 계정 해시 Secret이 있어야 한다(up.sh → create-secrets.sh가 만든다).
for s in db-accounts db-accounts-chat-ops; do
  k get secret "$s" -o name >/dev/null 2>&1 || { echo "Secret ${s}이 없습니다. 먼저 sudo bash scripts/ec2/up.sh" >&2; exit 1; }
done

work="$(mktemp -d)"
cleanup() {
  # 마스터 비밀번호를 클러스터와 디스크에 남기지 않는다.
  kubectl --context default -n "$ns" delete secret rds-master --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1) 마스터 비밀(JSON: username, password) → 파일 두 개(권한 600). 값은 출력하지 않는다.
umask 077
aws secretsmanager get-secret-value --region "$region" --secret-id "$arn" --query SecretString --output text >"$work/secret.json"
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
os.remove(os.path.join(d, "secret.json"))
PY

# 2) 임시 Secret(이전 실행이 남긴 것이 있으면 지우고 새로). create라 값은 표준 입력·파일로만 간다.
k delete secret rds-master --ignore-not-found >/dev/null
k create secret generic rds-master --from-file=PGUSER="$work/PGUSER" --from-file=PGPASSWORD="$work/PGPASSWORD" >/dev/null
rm -f "$work/PGUSER" "$work/PGPASSWORD"

# 3) SQL·본문 ConfigMap(kind와 같은 파일)과 Job. 이전 Job은 지우고 새로 만든다.
k create configmap db-bootstrap-rds \
  --from-file=db-bootstrap.sql="$root/environments/kind/data/db-bootstrap.sql" \
  --from-file=run-bootstrap.sh="$root/environments/kind/data/run-bootstrap.sh" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k delete job "$job" --ignore-not-found --wait=true >/dev/null
k apply -f "$root/environments/ec2/dev/rds-bootstrap/job.yaml" >/dev/null
echo "Job ${job} 실행 중(최대 10분)..."

# 4) 완료 또는 실패까지 기다린다.
result=""
for _ in $(seq 1 120); do
  if [ "$(k get job "$job" -o 'jsonpath={.status.succeeded}' 2>/dev/null)" = 1 ]; then result=ok; break; fi
  if [ "$(k get job "$job" -o 'jsonpath={.status.failed}' 2>/dev/null)" = 1 ]; then result=failed; break; fi
  sleep 5
done
k logs "job/$job" --tail=20 2>/dev/null || true
case "$result" in
  ok) echo "db-bootstrap-rds 완료. 마스터 Secret은 지운다." ;;
  failed) echo "db-bootstrap-rds 실패. 위 로그를 확인하세요(마스터 Secret은 지운다)." >&2; exit 1 ;;
  *) echo "10분 안에 끝나지 않았습니다. 마스터 Secret은 지운다. sudo k3s kubectl -n dev describe job/${job}" >&2; exit 1 ;;
esac
cat <<'EOF'
서비스 계정 비밀번호가 바뀌었거나 RDS로 처음 옮겼으면 앱을 다시 시작한다:
  sudo k3s kubectl -n dev rollout restart deployment
chat 마이그레이션(Alembic)은 Argo CD 동기화 때 돈다(docs/ec2-dev.md 'RDS').
EOF
