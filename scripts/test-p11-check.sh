#!/usr/bin/env bash
# scripts/kind/p11-check.sh가 "SQL을 실행하지 못한 경우"를 성공으로 세지 않는지 가짜 kubectl로 확인한다.
# 클러스터 없이 돈다(CI Helm 워크플로와 로컬에서 같이 쓴다).
set -euo pipefail
cd "$(dirname "$0")/.."

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
# 가짜 kubectl: FAKE_MODE에 따라 실패 모양을 만든다. 진짜 kubectl처럼 exec -i일 때만 표준 입력을 읽는다.
cat >"$fake/kubectl" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -i "*) cat >/dev/null 2>&1 || true ;; esac
case " $* " in
  *" get secret "*) printf 'dGVzdA==' ; exit 0 ;;   # "test"
esac
case "$FAKE_MODE" in
  exec_fail)    echo "error: pods \"postgres-0\" not found" >&2; exit 1 ;;
  silent_ok)    exit 0 ;;                                       # 아무것도 실행하지 않고 성공만 돌려줌
  auth_fail)    echo "psql: error: FATAL:  password authentication failed for user \"content_db_recommend\"" >&2; exit 2 ;;
  pass_but_connect_other_fail)
    # 1·2부와 자기 DB 접속은 그럴듯하게 성공하지만, 다른 DB 접속이 권한이 아닌 이유(서버 다운)로 실패
    case " $* " in
      *"select current_user"*) echo content_db_recommend; exit 0 ;;
      *"-d auth_db"*|*" auth_db "*|*" postgres -Atc"*) echo "psql: error: connection refused" >&2; exit 2 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
chmod +x "$fake/kubectl"

status=0
for mode in exec_fail silent_ok auth_fail pass_but_connect_other_fail; do
  if FAKE_MODE="$mode" PATH="$fake:$PATH" bash scripts/kind/p11-check.sh >/dev/null 2>&1; then
    echo "FAIL ${mode}: p11-check.sh가 성공(0)으로 끝났다"
    status=1
  else
    echo "ok   ${mode}: 실패로 끝남"
  fi
done
if KUBE_CONTEXT=arn:aws:eks:example PATH="$fake:$PATH" FAKE_MODE=silent_ok bash scripts/kind/p11-check.sh >/dev/null 2>&1; then
  echo "FAIL non-kind context: kind가 아닌 컨텍스트에서 실행됐다"; status=1
else
  echo "ok   non-kind context: 거부"
fi
exit "$status"
