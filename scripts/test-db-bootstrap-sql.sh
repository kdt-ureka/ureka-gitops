#!/usr/bin/env bash
# environments/kind/data/db-bootstrap.sql을 실제 PostgreSQL 18(kind와 같은 pgvector 이미지)에서 두 번씩 돌린다(Docker 필요).
#   super    kind처럼 슈퍼유저(postgres)로 실행
#   rdslike  RDS 마스터처럼 슈퍼유저가 아닌 CREATEDB·CREATEROLE 계정으로 실행(PostgreSQL 16+ 권한 규칙)
# 두 경우 모두 같은 최종 상태(계정 속성·DB 소유자·접속 권한·멤버십·검색 계정 설정·비밀번호)인지 확인한다.
# 같은 서버에 접미사 _prod(EKS prod, #63 후속)로 한 벌 더 만들고: prod 상태가 같은 구조인지, dev 상태가 그대로인지,
# dev 계정은 prod DB에·prod 계정은 dev DB에 접속하지 못하는지, 잘못된 접미사는 아무것도 만들지 않는지 본다.
# rdslike: 일반 PostgreSQL에서는 vector를 슈퍼유저만 설치할 수 있다. RDS에서는 rds_superuser가 설치할 수 있으므로,
#   시험 컨테이너에서만 vector를 신뢰 확장(trusted)으로 표시해 SQL 본문의 CREATE EXTENSION ... SCHEMA catalog가 그대로 돌게 한다.
# 두 경우 모두 vector가 catalog 스키마에 있고(catalog.vector 타입) public에는 없어야 한다.
# 한계: RDS 전용 제약(rds_superuser 고유 권한, postgres DB 소유자, pgvector 0.8.2)은 실제 RDS 첫 실행에서 확인한다.
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

# 해시 변수 이름은 dev·prod가 같다(실제로는 서로 다른 Secret). 시험은 접미사마다 비밀번호를 달리 한다:
# dev는 test-pw-<변수>, prod는 test-pw-<변수>_prod.
envs_for() { # 접미사
  envs=()
  local v
  for v in AUTH_DB_APP CONTENT_DB_APP CONTENT_DB_RECOMMEND CONTENT_DB_INGEST CHAT_DB_APP OPS_DB_APP; do
    envs+=(-e "${v}_SCRAM=$(scram "test-pw-$v$1")")
  done
}

expected="$(cat <<'END'
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
END
)"
# prod는 같은 구조에 이름만 <db>_prod(content_db_app → content_db_prod_app, content_db_recommend → content_db_prod_recommend).
expected_prod="$(printf '%s\n' "$expected" | sed -E 's/(auth|chat|content|ops)_db/\1_db_prod/g')"

run_sql() { # 접미사(빈 값이면 db_suffix 변수를 넘기지 않음 = 기존 호출과 같음) → 출력, 종료 코드
  envs_for "$1"
  local var=()
  [ -z "$1" ] || var=(-v "db_suffix=$1")
  docker exec "${envs[@]}" -e PGPASSWORD="$pass" "$name" \
    psql -h 127.0.0.1 -U "$user" -d postgres -v ON_ERROR_STOP=1 ${var[@]+"${var[@]}"} -X -q -f /tmp/bootstrap.sql 2>&1
}

login() { # 비밀번호 변수 이름, 접미사, 역할, DB → 접속되면 0
  docker exec -e PGPASSWORD="test-pw-$1$2" "$name" psql -h 127.0.0.1 -U "$3" -d "$4" -At -c 'SELECT 1' >/dev/null 2>&1
}

check_env() { # 접미사, 기대 상태, 표시 이름. 접미사가 비면 _prod 이름은 뺀다.
  local sfx="$1" want="$2" label="$3" rfilter dfilter
  if [ -z "$sfx" ]; then
    rfilter="rolname NOT LIKE '%\\_prod%'"; dfilter="datname LIKE '%\\_db'"
  else
    rfilter="rolname LIKE '%\\_db${sfx}%'"; dfilter="datname LIKE '%\\_db${sfx}'"
  fi
  local state
  state="$(docker exec "$name" psql -U postgres -At -d postgres -c "
SELECT 'role '||rolname||' login='||rolcanlogin||' super='||rolsuper||' createdb='||rolcreatedb||' createrole='||rolcreaterole||' repl='||rolreplication||' bypass='||rolbypassrls
  FROM pg_roles WHERE rolname LIKE '%db\\_%' AND rolname <> 'ureka_admin' AND ${rfilter} ORDER BY 1;
SELECT 'db '||datname||' owner='||pg_get_userbyid(datdba) FROM pg_database WHERE ${dfilter} ORDER BY 1;
SELECT 'member '||pg_get_userbyid(roleid)||' -> '||pg_get_userbyid(member)||' inh='||inherit_option||' set='||set_option
  FROM pg_auth_members WHERE pg_get_userbyid(member) IN ('content_db${sfx}_recommend', 'content_db${sfx}_ingest') ORDER BY 1;
SELECT 'setting '||array_to_string(setconfig, ',') FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'content_db${sfx}_recommend';")
$(docker exec "$name" psql -U postgres -At -d "content_db${sfx}" -c "SELECT 'schema catalog owner='||pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'catalog';")"
  if [ "$state" = "$want" ]; then ok "${label}: 최종 상태가 기대와 같음"; else fail "${label}: 최종 상태가 다름"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$state") || true; fi

  local vec
  vec="$(docker exec "$name" psql -U postgres -At -d "content_db${sfx}" -c "
SELECT n.nspname || ' ' || (to_regtype('catalog.vector') IS NOT NULL) || ' ' || (to_regtype('public.vector') IS NULL)
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'")"
  if [ "$vec" = "catalog true true" ]; then
    ok "${label}: vector 확장이 catalog 스키마(catalog.vector 있음, public.vector 없음)"
  else
    fail "${label}: vector 확장 위치가 다름(스키마·catalog 타입·public 없음: ${vec:-확장 없음})"
  fi
}

run_twice() { # 접미사, 표시 이름 → 실패하면 1
  local run rc out
  for run in 1 2; do
    rc=0
    out="$(run_sql "$1")" || rc=$?
    if [ "$rc" = 0 ]; then ok "$2: 실행 ${run}회차 성공"; else fail "$2: 실행 ${run}회차 실패(rc=${rc})"; printf '%s\n' "$out" | grep -E 'ERROR' | head -3; return 1; fi
  done
}

run_mode() { # super|rdslike
  local mode="$1"
  name="ureka-bootstrap-sql-test-$1-$$" user=postgres pass=test-super
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -e POSTGRES_PASSWORD=test-super "$img" >/dev/null
  trap 'docker rm -f "'"$name"'" >/dev/null 2>&1 || true' RETURN
  for _ in $(seq 1 60); do docker exec "$name" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
  docker cp "$sql" "$name:/tmp/bootstrap.sql"
  if [ "$mode" = rdslike ]; then
    docker exec "$name" sh -c 'ctl="$(pg_config --sharedir)/extension/vector.control"; grep -q "^trusted" "$ctl" || echo "trusted = true" >>"$ctl"'
    docker exec "$name" psql -U postgres -q -d postgres -c "CREATE ROLE ureka_admin LOGIN CREATEDB CREATEROLE PASSWORD 'test-admin'"
    user=ureka_admin pass=test-admin
  fi

  run_twice "" "${mode} dev" || return 0
  check_env "" "$expected" "${mode} dev"

  # prod(접미사 _prod): 같은 서버에 두 번째 벌. dev 상태는 그대로여야 한다.
  run_twice _prod "${mode} prod" || return 0
  check_env _prod "$expected_prod" "${mode} prod"
  check_env "" "$expected" "${mode} dev(prod 실행 뒤)"

  # 잘못된 접미사: 실패하고 아무 역할도 만들지 않는다.
  local rc=0
  run_sql _x >/dev/null || rc=$?
  if [ "$rc" != 0 ] && [ "$(docker exec "$name" psql -U postgres -At -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname LIKE '%\\_x%'")" = 0 ]; then
    ok "${mode}: 접미사 _x는 실패, 만든 역할 없음"
  else
    fail "${mode}: 접미사 _x가 거부되지 않음(rc=${rc})"
  fi

  # 서비스 계정 접속: 자기 DB만 된다(비밀번호가 해시대로 들어갔는지도 함께 본다).
  # dev 계정은 prod DB에, prod 계정은 dev DB에 접속하지 못한다(검색·적재 계정은 Flyway 전이라 아직 CONNECT가 없다: 아래 note).
  local svc db sfx env_name role own other
  for sfx in "" _prod; do
    for svc in auth_db_app:auth_db chat_db_app:chat_db ops_db_app:ops_db content_db_app:content_db; do
      db="${svc#*:}"; svc="${svc%%:*}"
      env_name="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')"
      role="${svc/_db/_db${sfx}}"; own="${db}${sfx}"
      if [ -z "$sfx" ]; then other="${db}_prod"; else other="$db"; fi
      if login "$env_name" "$sfx" "$role" "$own"; then ok "${mode}: ${role} → ${own} 접속"; else fail "${mode}: ${role} → ${own} 접속 실패"; fi
      if login "$env_name" "$sfx" "$role" "$other"; then fail "${mode}: ${role}이 ${other}에 접속된다(환경 경계)"; else ok "${mode}: ${role}은 ${other}에 접속 못 함"; fi
    done
    # 검색·적재 계정: 자기 환경 content DB에만 CONNECT(역할 상속), 다른 환경 content DB에는 없음.
    for svc in content_db_recommend content_db_ingest; do
      role="${svc/_db/_db${sfx}}"; own="content_db${sfx}"
      if [ -z "$sfx" ]; then other=content_db_prod; else other=content_db; fi
      env_name="$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')"
      if login "$env_name" "$sfx" "$role" "$own"; then ok "${mode}: ${role} → ${own} 접속"; else fail "${mode}: ${role} → ${own} 접속 실패"; fi
      if login "$env_name" "$sfx" "$role" "$other"; then fail "${mode}: ${role}이 ${other}에 접속된다(환경 경계)"; else ok "${mode}: ${role}은 ${other}에 접속 못 함"; fi
    done
  done
  # 역할 상속이 환경을 넘지 않는지: prod 로그인 계정이 dev 역할의 멤버가 아니고, 그 반대도 아니다(관리자 멤버십은 제외).
  local cross
  cross="$(docker exec "$name" psql -U postgres -At -d postgres -c "
SELECT count(*) FROM pg_auth_members m
  JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member
 WHERE u.rolname LIKE '%db\\_%' AND g.rolname LIKE '%db\\_%'
   AND ((u.rolname LIKE '%\\_prod%') <> (g.rolname LIKE '%\\_prod%'))")"
  if [ "$cross" = 0 ]; then ok "${mode}: dev·prod 사이 역할 멤버십 없음"; else fail "${mode}: dev·prod 사이 역할 멤버십 ${cross}개"; fi

  if login AUTH_DB_APP "" auth_db_app content_db; then
    fail "${mode}: auth_db_app이 content_db에 접속된다"
  else
    ok "${mode}: auth_db_app은 content_db에 접속 못 함"
  fi
  # 관리용 postgres DB의 CONNECT 회수는 그 DB 소유자만 할 수 있다. 슈퍼유저(kind)는 반드시 막혀야 한다.
  # rdslike에서는 소유자가 슈퍼유저라 회수되지 않는다(경고만). 실제 RDS는 소유자에 따라 다르므로 첫 실행에서 확인한다.
  if login AUTH_DB_APP "" auth_db_app postgres; then
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
