#!/usr/bin/env bash
# scripts/kind/create-secrets.sh 회귀 시험. 클러스터 없이 가짜 kubectl로 돈다(CI Helm 워크플로와 로컬에서 같이 쓴다).
# - 조회가 NotFound가 아닌 오류(Forbidden·연결 실패)면 Secret을 하나도 만들지 않고 실패해야 한다.
# - 이미 있는 Secret은 덮어쓰지 않는다(전부 있으면 아무것도 안 함, 일부만 있으면 실패).
# - 모두 없을 때만 6개를 create로 만든다(apply 아님).
set -euo pipefail
cd "$(dirname "$0")/.."

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

cat >"$fake/kubectl" <<'SH'
#!/usr/bin/env bash
mode="${FAKE_MODE:-none_exist}"
log="${FAKE_LOG:?}"
args=" $* "
nf() { echo "Error from server (NotFound): $1 \"$2\" not found" >&2; exit 1; }
forbid() { echo "Error from server (Forbidden): $1 \"$2\" is forbidden: User cannot get resource" >&2; exit 1; }
case "$args" in
  *" get namespace "*)
    [ "$mode" = ns_forbidden ] && forbid namespaces dev
    exit 0 ;;
  *" get "*" secret "*)
    name="${*: -3:1}"
    case "$mode" in
      secret_forbidden) forbid secrets "$name" ;;
      conn_refused) echo "The connection to the server 127.0.0.1:6443 was refused" >&2; exit 1 ;;
      all_exist) exit 0 ;;
      partial) [ "$name" = postgres-admin ] && exit 0; nf secrets "$name" ;;
    esac
    nf secrets "$name" ;;
  *" get "*" pvc "*)
    case "$mode" in
      pvc_forbidden) forbid persistentvolumeclaims data-postgres-0 ;;
      pvc_exists) exit 0 ;;
    esac
    nf persistentvolumeclaims data-postgres-0 ;;
  *" create secret generic "*"--dry-run=client"*)
    echo "apiVersion: v1"; echo "kind: Secret"; exit 0 ;;
  *" label "*"--local"*)
    cat; exit 0 ;;
  *" create -f - "*)
    cat >/dev/null
    # 확인과 생성 사이에 누가 같은 이름을 만든 경우: 세 번째 create에서 AlreadyExists
    if [ "$mode" = already_exists_on_create ] && [ "$(grep -c CREATE "$log")" -eq 2 ]; then
      echo 'Error from server (AlreadyExists): secrets "ureka-auth-secrets" already exists' >&2; exit 1
    fi
    echo CREATE >>"$log"; exit 0 ;;
  *" apply "*)
    echo APPLY >>"$log"; exit 0 ;;
esac
echo "가짜 kubectl: 처리하지 않은 호출 $*" >&2
exit 1
SH
chmod +x "$fake/kubectl"

status=0
check() { # 모드, 기대 종료(0|nonzero), 기대 create 수
  local mode="$1" want_rc="$2" want_creates="$3" rc=0 creates
  : >"$fake/log"
  FAKE_MODE="$mode" FAKE_LOG="$fake/log" PATH="$fake:$PATH" bash scripts/kind/create-secrets.sh </dev/null >"$fake/out" 2>&1 || rc=$?
  creates="$(grep -c CREATE "$fake/log" || true)"
  if grep -q APPLY "$fake/log"; then echo "FAIL ${mode}: apply를 썼다(덮어쓸 수 있음)"; status=1; return; fi
  if { [ "$want_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$want_rc" = nonzero ] && [ "$rc" -eq 0 ]; } || [ "$creates" -ne "$want_creates" ]; then
    echo "FAIL ${mode}: 종료 ${rc}(기대 ${want_rc}), create ${creates}개(기대 ${want_creates})"; tail -3 "$fake/out"; status=1
  else
    echo "ok   ${mode}: 종료 ${rc}, create ${creates}개"
  fi
}

check none_exist        0       6
check all_exist         0       0
check partial           nonzero 0
check pvc_exists        nonzero 0
check secret_forbidden  nonzero 0
check pvc_forbidden     nonzero 0
check ns_forbidden      nonzero 0
check conn_refused      nonzero 0
# 중간 실패: 앞의 2개는 남고 스크립트는 실패로 끝난다(덮어쓰지 않음). 다음 실행은 '일부만 있음'으로 멈춘다.
check already_exists_on_create nonzero 2

: >"$fake/log"
if KUBE_CONTEXT=arn:aws:eks:example FAKE_LOG="$fake/log" PATH="$fake:$PATH" bash scripts/kind/create-secrets.sh </dev/null >/dev/null 2>&1; then
  echo "FAIL non-kind context: 실행됐다"; status=1
else
  echo "ok   non-kind context: 거부"
fi
exit "$status"
