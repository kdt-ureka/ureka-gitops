#!/usr/bin/env bash
# No tracing or raw psql/pg_dump output. Dump+diagnostics live only in the Job emptyDir.
{ set +x; } 2>/dev/null
set -euo pipefail
case "$#:${1:-}" in
  0:) ;;
  1:--verify-only) ;;
  *) echo 'copy failed 1' >&2; exit 1 ;;
esac
umask 077
cd /copy
work="$(mktemp -d /work/copy.XXXXXXXX)"
source_pid=""
phase=1
cleanup() {
  if [ -n "$source_pid" ]; then
    kill "$source_pid" 2>/dev/null || true
    wait "$source_pid" 2>/dev/null || true
  fi
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
fail() { echo "copy failed $phase" >&2; exit 1; }
# Wrong DB names cannot be supplied by CLI/environment. Both connections use the same PGHOST/TLS/master.
psql_common=(psql -X -q -A -t --set=ON_ERROR_STOP=1)
export PGCONNECT_TIMEOUT=10
export PGOPTIONS='-c search_path=pg_catalog -c client_min_messages=warning -c log_statement=none -c log_min_error_statement=panic'
# Freeze source tables through an independent live connection, including seed/Flyway rows.
# SHARE blocks writers/DDL but permits reads and pg_dump. No source data is modified.
mkfifo "$work/source.in" "$work/source.out"
PGDATABASE=content_db "${psql_common[@]}" <"$work/source.in" >"$work/source.out" 2>"$work/freeze.err" &
source_pid="$!"
exec 7>"$work/source.in"
exec 8<"$work/source.out"
printf '%s\n' 'BEGIN;' "SET LOCAL lock_timeout='5s';" '\i /copy/policy.sql' \
 "SELECT 'LOCK TABLE '||string_agg(name,', ' ORDER BY name)||' IN SHARE MODE;' FROM copy_policy" '\gexec' \
 "SELECT 'frozen';" >&7
IFS= read -r -t 30 marker <&8 || fail
[ "$marker" = frozen ] || fail
sql() { local db="$1"; shift; PGDATABASE="$db" "${psql_common[@]}" "$@" 2>"$work/error"; }
phase=2
# Equal successful Flyway chain/latest version, reviewed table inventory/columns and seeds.
for side in source prod; do
  db=content_db; [ "$side" = source ] || db=content_db_prod
  { echo '\i /copy/policy.sql'; echo '\i /copy/metadata.sql'; } | sql "$db" >"$work/$side.meta" || fail
done
cmp -s "$work/source.meta" "$work/prod.meta" || fail
# Existing prod data after an EKS recreation: compare without any destination COPY/DDL.
# Uses the same shared Lease, frozen source, reviewed metadata/report and cleanup path.
# Prepare temporary tables before READ ONLY (PostgreSQL rejects CREATE even for TEMP there).
# All persistent destination reads/validation use one READ ONLY snapshot.
if [ "${1:-}" = --verify-only ]; then
  phase=3
  export PGOPTIONS="$PGOPTIONS -c timezone=UTC"
  [ "$(sql content_db -c "SELECT (count(*)>0)::int FROM catalog.contents")" = 1 ] || fail
  [ "$(sql content_db -c "SELECT count(*) FROM ingest.ingestion_runs WHERE status='running'")" = 0 ] || fail
  { echo '\i /copy/policy.sql'; echo '\i /copy/report-hash.sql'; echo '\i /copy/verify-hash.sql'; } | sql content_db >"$work/source.report" || fail
  {
    echo '\i /copy/policy.sql'
    echo 'CREATE TEMP TABLE row_counts(name text, n bigint);'
    echo 'CREATE TEMP TABLE verify_hashes(name text PRIMARY KEY, digest text);'
    echo 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;'
    echo '\i /copy/validate.sql'
    sed '/^CREATE TEMP TABLE row_counts(name text, n bigint);$/d' /copy/report-hash.sql
    sed '/^CREATE TEMP TABLE verify_hashes(name text PRIMARY KEY, digest text);$/d' /copy/verify-hash.sql
    echo 'COMMIT;'
  } | sql content_db_prod >"$work/prod.report" || fail
  cmp -s "$work/source.report" "$work/prod.report" || fail
  kill -0 "$source_pid" 2>/dev/null || fail
  echo 'copy ok'
  exit 0
fi
phase=3
{ echo '\i /copy/policy.sql'; echo '\i /copy/empty.sql'; } | sql content_db_prod >"$work/check" || fail
[ "$(sql content_db -c "SELECT (count(*)>0)::int FROM catalog.contents")" = 1 ] || fail
# Refuse a live ingest snapshot even if no writer currently holds a lock.
[ "$(sql content_db -c "SELECT count(*) FROM ingest.ingestion_runs WHERE status='running'")" = 0 ] || fail
mapfile -t tables < <(sql content_db -f policy.sql -c "SELECT name FROM copy_policy WHERE mode='copy' ORDER BY name")
[ "${#tables[@]}" = 15 ] || fail
args=()
for table in "${tables[@]}"; do args+=(--table="$table"); done
# Include only sequences owned by copied tables; never a user/search-history sequence.
mapfile -t sequences < <(sql content_db -f policy.sql -c "SELECT DISTINCT pg_get_serial_sequence(name,a.attname) FROM copy_policy JOIN pg_attribute a ON a.attrelid=name::regclass AND a.attnum>0 AND NOT a.attisdropped WHERE mode='copy' AND pg_get_serial_sequence(name,a.attname) IS NOT NULL ORDER BY 1")
[ "${#sequences[@]}" = 3 ] || fail
for seq in "${sequences[@]}"; do args+=(--table="$seq"); done
{ echo '\i /copy/policy.sql'; echo '\i /copy/report-hash.sql'; } | sql content_db >"$work/source.report" || fail
expected_meta="$(cat "$work/source.meta")"
expected_report="$(cat "$work/source.report")"
[[ "$expected_meta" =~ ^[0-9a-f]{32}$ && "$expected_report" =~ ^[0-9a-f]{32}$ ]] || fail
phase=4
PGDATABASE=content_db pg_dump --data-only --no-owner --no-privileges --no-publications --no-subscriptions \
  --no-large-objects --strict-names "${args[@]}" --file="$work/data.sql" 2>"$work/dump.err" || fail
# A dead lock-holder invalidates the run; do not restore or commit after losing the freeze.
kill -0 "$source_pid" 2>/dev/null || fail
phase=5
# All destination checks + COPY + FK/trigger-equivalent checks + grouped comparison are one transaction.
# SET LOCAL replica fails before COPY if the RDS master lacks SET permission (no fallback disable-trigger hacks).
{
  echo 'BEGIN;'
  echo "SET LOCAL lock_timeout='5s';"
  echo '\i /copy/policy.sql'
  echo "SELECT 'LOCK TABLE '||string_agg(name,', ' ORDER BY name)||' IN ACCESS EXCLUSIVE MODE;' FROM copy_policy"
  echo '\gexec'
  echo '\i /copy/empty.sql'
  echo "\\o $work/prod.locked.meta"
  echo '\i /copy/metadata.sql'
  echo '\o'
  # Compare metadata inside this same locked transaction. psql variables contain only fixed hex.
  echo "\\set expected_meta $expected_meta"
  echo "\\set actual_meta \`cat $work/prod.locked.meta\`"
  echo "SELECT 1/(CASE WHEN :'actual_meta'=:'expected_meta' THEN 1 ELSE 0 END);"
  echo "SET LOCAL session_replication_role=replica;"
  cat "$work/data.sql"
  echo 'SET LOCAL session_replication_role=origin;'
  echo '\i /copy/validate.sql'
  echo "\\o $work/prod.report"
  echo '\i /copy/report-hash.sql'
  echo '\o'
  echo "\\set expected_report $expected_report"
  echo "\\set actual_report \`cat $work/prod.report\`"
  echo "SELECT 1/(CASE WHEN :'actual_report'=:'expected_report' THEN 1 ELSE 0 END);"
  echo '\i /copy/numbers.sql'
  # Recheck holder immediately before COMMIT through a local psql command; failure aborts the SQL session.
  echo "\\! kill -0 $source_pid"
  echo '\if :SHELL_ERROR'
  echo 'SELECT 1/0;'
  printf '%s\n' '\endif'
  echo 'COMMIT;'
} | sql content_db_prod >"$work/restore.out" || fail
phase=6
# Only numeric report rows from the verified source and committed destination may reach logs.
echo 'copy source'
sql content_db -f numbers.sql | grep -E '^copy (contents|documents|embeddings|runs) [0-9 -]+$' || fail
echo 'copy prod'
grep -E '^copy (contents|documents|embeddings|runs) [0-9 -]+$' "$work/restore.out" || fail
echo 'copy ok'
