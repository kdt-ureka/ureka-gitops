#!/usr/bin/env bash
# environments/kind/data/db-bootstrap.sql을 실제 PostgreSQL 18(kind와 같은 pgvector 이미지)에서 두 번씩 돌린다(Docker 필요).
#   super    kind처럼 슈퍼유저(postgres)로 실행
#   rdslike  RDS 마스터처럼 슈퍼유저가 아닌 CREATEDB·CREATEROLE 계정으로 실행(PostgreSQL 16+ 권한 규칙)
# 두 경우 모두 같은 최종 상태(계정 속성·DB 소유자·접속 권한·멤버십·검색 계정 설정·비밀번호)인지 확인한다.
# 한계: 일반 PostgreSQL에서는 vector를 슈퍼유저만 설치할 수 있어, rdslike는 template1에 미리 설치해 둔다
#      (RDS에서는 rds_superuser가 직접 설치한다). RDS 전용 제약은 실제 RDS 첫 실행에서 확인한다.
# 비밀번호는 시험용 고정 문자열이다(컨테이너는 끝나면 지운다).
set -euo pipefail
cd "$(dirname "$0")/.."

img='pgvector/pgvector:0.8.7-pg18-trixie@sha256:5895949dfcdf308eb0cd31c950c93c14895c77f33fbedfecf1fa511ab1d4bcd2'
sql="${1:-environments/kind/data/db-bootstrap.sql}"
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }

scram() { # 원문 → SCRAM-SHA-256 verifier (create-secrets.sh와 같은 형식)
  python3 -I -c '
import base64, hashlib, hmac, os, sys
pw = sys.argv[1].encode(); salt = os.urandom(16); it = 4096
s = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
ck = hmac.new(s, b"Client Key", "sha256").digest(); sk = hmac.new(s, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
print("SCRAM-SHA-256$%d:%s$%s:%s" % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))' "$1"
}

envs=()
for v in AUTH_DB_APP CONTENT_DB_APP CONTENT_DB_RECOMMEND CONTENT_DB_INGEST CHAT_DB_APP OPS_DB_APP; do
  envs+=(-e "${v}_SCRAM=$(scram "test-pw-$v")")
done

expected="$(cat <<'EOF'
role auth_db_app login=true super=false createdb=false createrole=false repl=false bypass=false
role chat_db_app login=true super=false createdb=false createrole=false repl=false bypass=false
role content_db_app login=true super=false createdb=false createrole=true repl=false bypass=false
role content_db_ingest login=true super=false createdb=false createrole=false repl=false bypass=false
role content_db_ingest_writer login=false super=false createdb=false createrole=false repl=false bypass=false
role content_db_recommend login=true super=false createdb=false createrole=false repl=false bypass=false
role content_db_recommend_search login=false super=false createdb=false createrole=false repl=false bypass=false
role ops_db_app login=true super=false createdb=false createrole=false repl=false bypass=false
db auth_db owner=auth_db_app
db chat_db owner=chat_db_app
db content_db owner=content_db_app
db ops_db owner=ops_db_app
member content_db_ingest_writer -> content_db_ingest inh=true set=false
member content_db_recommend_search -> content_db_recommend inh=true set=false
setting default_transaction_read_only=on,statement_timeout=5s,idle_in_transaction_session_timeout=10s
schema catalog owner=content_db_app
EOF
)"

run_mode() { # super|rdslike
  local mode="$1" name="ureka-bootstrap-sql-test-$1-$$" user=postgres pass=test-super
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -e POSTGRES_PASSWORD=test-super "$img" >/dev/null
  trap 'docker rm -f "'"$name"'" >/dev/null 2>&1 || true' RETURN
  for _ in $(seq 1 60); do docker exec "$name" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
  docker cp "$sql" "$name:/tmp/bootstrap.sql"
  if [ "$mode" = rdslike ]; then
    docker exec "$name" psql -U postgres -q -d template1 \
      -c "CREATE ROLE ureka_admin LOGIN CREATEDB CREATEROLE PASSWORD 'test-admin'" -c "CREATE EXTENSION vector"
    user=ureka_admin pass=test-admin
  fi
  local run rc out
  for run in 1 2; do
    rc=0
    out="$(docker exec "${envs[@]}" -e PGPASSWORD="$pass" "$name" \
      psql -h 127.0.0.1 -U "$user" -d postgres -v ON_ERROR_STOP=1 -X -q -f /tmp/bootstrap.sql 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then ok "${mode}: 실행 ${run}회차 성공"; else fail "${mode}: 실행 ${run}회차 실패(rc=${rc})"; printf '%s\n' "$out" | grep -E 'ERROR' | head -3; return; fi
  done
  local state
  state="$(docker exec "$name" psql -U postgres -At -d postgres -c "
SELECT 'role '||rolname||' login='||rolcanlogin||' super='||rolsuper||' createdb='||rolcreatedb||' createrole='||rolcreaterole||' repl='||rolreplication||' bypass='||rolbypassrls
  FROM pg_roles WHERE rolname LIKE '%db\_%' AND rolname <> 'ureka_admin' ORDER BY 1;
SELECT 'db '||datname||' owner='||pg_get_userbyid(datdba) FROM pg_database WHERE datname LIKE '%\_db' ORDER BY 1;
SELECT 'member '||pg_get_userbyid(roleid)||' -> '||pg_get_userbyid(member)||' inh='||inherit_option||' set='||set_option
  FROM pg_auth_members WHERE pg_get_userbyid(member) IN ('content_db_recommend', 'content_db_ingest') ORDER BY 1;
SELECT 'setting '||array_to_string(setconfig, ',') FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'content_db_recommend';")
$(docker exec "$name" psql -U postgres -At -d content_db -c "SELECT 'schema catalog owner='||pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog';")"
  if [ "$state" = "$expected" ]; then ok "${mode}: 최종 상태가 기대와 같음"; else fail "${mode}: 최종 상태가 다름"; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$state") || true; fi

  if docker exec "$name" psql -U postgres -At -d content_db -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector'" | grep -qx 1; then
    ok "${mode}: content_db에 vector 확장"
  else
    fail "${mode}: content_db에 vector 확장 없음"
  fi
  # 서비스 계정 접속: 자기 DB만 된다(비밀번호가 해시대로 들어갔는지도 함께 본다)
  local svc db
  for svc in auth_db_app:auth_db chat_db_app:chat_db ops_db_app:ops_db content_db_app:content_db; do
    db="${svc#*:}"; svc="${svc%%:*}"
    local env_name; env_name="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')"
    if docker exec -e PGPASSWORD="test-pw-${env_name}" "$name" psql -h 127.0.0.1 -U "$svc" -d "$db" -At -c 'SELECT 1' >/dev/null 2>&1; then
      ok "${mode}: ${svc} → ${db} 접속"
    else
      fail "${mode}: ${svc} → ${db} 접속 실패"
    fi
  done
  if docker exec -e PGPASSWORD=test-pw-AUTH_DB_APP "$name" psql -h 127.0.0.1 -U auth_db_app -d content_db -At -c 'SELECT 1' >/dev/null 2>&1; then
    fail "${mode}: auth_db_app이 content_db에 접속된다"
  else
    ok "${mode}: auth_db_app은 content_db에 접속 못 함"
  fi
  # 관리용 postgres DB의 CONNECT 회수는 그 DB 소유자만 할 수 있다. 슈퍼유저(kind)는 반드시 막혀야 한다.
  # rdslike에서는 소유자가 슈퍼유저라 회수되지 않는다(경고만). 실제 RDS는 소유자에 따라 다르므로 첫 실행에서 확인한다.
  if docker exec -e PGPASSWORD=test-pw-AUTH_DB_APP "$name" psql -h 127.0.0.1 -U auth_db_app -d postgres -At -c 'SELECT 1' >/dev/null 2>&1; then
    if [ "$mode" = super ]; then fail "${mode}: auth_db_app이 postgres DB에 접속된다"; else echo "note ${mode}: auth_db_app이 postgres DB에 접속된다(소유자가 아니라 회수 못 함, RDS에서 확인)"; fi
  else
    ok "${mode}: auth_db_app은 postgres DB에 접속 못 함"
  fi
}

command -v docker >/dev/null || { echo "docker가 필요합니다" >&2; exit 1; }
docker pull -q "$img" >/dev/null
run_mode super
run_mode rdslike
exit "$status"
