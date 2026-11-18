#!/usr/bin/env bash
# scripts/ec2/ingest.sh·scripts/ec2/ingest/{csvtool,recv}.py 회귀 시험. 가짜 kubectl·id로 돈다(클러스터·AWS·실제 CSV 없음).
# 가짜 kubectl은 apply 입력을 파일로 남기고, "exec ... python /tools/csvtool.py"는 이 PC의 python으로 csvtool을 직접 돌린다.
# check()가 eval로 쓰는 변수(out·job_file 등)를 shellcheck가 미사용으로 본다.
# shellcheck disable=SC2034
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ng() { fail=$((fail + 1)); echo "FAIL $1" >&2; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

mkdir -p "$t/bin" "$t/etc" "$t/input" "$t/output" "$t/upload" "$t/applied"
printf 'ECR_REGISTRY=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com\nAWS_REGION=ap-northeast-2\n' >"$t/etc/registry.env"
cat >"$t/bin/id" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
cat >"$t/bin/kubectl" <<SH
#!/usr/bin/env bash
# 가짜 kubectl: 호출을 기록하고, 시험에 필요한 응답만 흉내 낸다.
echo "\$*" >>"$t/kubectl.log"
args=" \$* "
case "\$args" in
  *" apply -f - "*) n=\$(ls "$t/applied" | wc -l | tr -d ' '); cat >"$t/applied/\$n.yaml"; echo applied ;;
  *" create configmap "*) echo "kind: ConfigMap" ;;
  *" get pod ingest-files -o jsonpath="*) echo Running ;;
  *" get pod ingest-report -o jsonpath="*) echo "\${FAKE_REPORT_PHASE:-Succeeded}" ;;
  *" logs ingest-report"*) echo "[검색 가능 작품]" ;;
  *" get pod ingest-files "*) exit 1 ;; # 아직 없음(prepare가 새로 만든다)
  *" get jobs "*"status.active"*) printf '%s' "\${FAKE_ACTIVE:-}" ;;
  *" get jobs "*) echo ingest-load-sample-202611181200 ;;
  *" get secret "*) exit 0 ;;
  *" exec "*"/tools/csvtool.py"*)
    rest="\${args#*/tools/csvtool.py }"
    INGEST_INPUT_DIR="$t/input" INGEST_OUTPUT_DIR="$t/output" exec python3 -I "$root/scripts/ec2/ingest/csvtool.py" \$rest ;;
  *) exit 0 ;;
esac
SH
chmod +x "$t/bin/id" "$t/bin/kubectl"
export PATH="$t/bin:$PATH" UREKA_ETC_DIR="$t/etc" UREKA_INGEST_UPLOAD_DIR="$t/upload"
run() { bash "$root/scripts/ec2/ingest.sh" "$@"; }

# 시험용 CSV: 공통 6행(movie 3·tv 3, 칸 안 줄바꿈 포함), 상세는 movie 2·tv 3(movie 하나는 상세 없음).
u() { printf '00000000-0000-4000-8000-%012d' "$1"; }
{
  printf '\xef\xbb\xbfcontent_id,media_type,overview\n'
  printf '%s,movie,"첫 줄\n둘째 줄"\n' "$(u 1)"
  printf '%s,tv,a\n' "$(u 2)"
  printf '%s,movie,b\n' "$(u 3)"
  printf '%s,tv,c\n' "$(u 4)"
  printf '%s,movie,d\n' "$(u 5)"
  printf '%s,tv,e\n' "$(u 6)"
} >"$t/upload/01_공통_common_staging_v0_0_21.csv"
printf 'content_id,x\n%s,1\n%s,1\n' "$(u 1)" "$(u 5)" >"$t/upload/02_movie_details_staging_v0_0_21.csv"
printf 'content_id,x\n%s,1\n%s,1\n%s,1\n' "$(u 2)" "$(u 4)" "$(u 6)" >"$t/upload/03_tv_series_details_staging_v0_0_21.csv"
cp "$t/upload/"*.csv "$t/"

# root가 아니면 거절
out="$(PATH="${PATH#"$t/bin:"}" bash "$root/scripts/ec2/ingest.sh" stat 2>&1 || true)"
check "root가 아니면 거절" '[[ "$out" == *"root로 실행하세요"* ]] || [ "$(/usr/bin/id -u)" = 0 ]'

# prepare: 저장소·정책·파일 Pod. 레지스트리 주소는 화면에 안 나온다.
out="$(run prepare 2>&1)"
check "prepare 성공" '[[ "$out" == *"준비 완료"* ]]'
check "prepare 출력에 계정 ID 없음" '[[ "$out" != *123456789012* ]]'
files_pod="$(grep -l 'name: ingest-files' "$t/applied/"*.yaml | head -n1)"
check "파일 Pod에 레지스트리가 들어감" 'grep -q "image: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/ingest:sha-b57c76a" "$files_pod"'
check "파일 Pod에 남은 자리 없음" '! grep -v "^ *#" "$files_pod" | grep -q "__"'

# store: 세 파일 PVC로(가짜: $t/input), sha256 같으면 서버 사본 삭제
out="$(run store 2>&1)"
check "store sha256 일치" '[ "$(grep -c "^같음" <<<"$out")" = 3 ]'
check "store 뒤 서버 사본 삭제" '[ -z "$(ls "$t/upload")" ]'
check "PVC 파일이 원본과 같음" 'cmp -s "$t/01_공통_common_staging_v0_0_21.csv" "$t/input/01_공통_common_staging_v0_0_21.csv"'
check "임시 .part 없음" '[ -z "$(ls -A "$t/input" | grep part || true)" ]'

# stat: 행 수는 칸 안 줄바꿈을 한 행으로, BOM·머리글 제외
out="$(run stat 2>&1)"
check "공통 행 수 6" 'grep -q "\"rows\": 6" <<<"$(grep 01_ <<<"$out")"'
check "movie 행 수 2" 'grep -q "\"rows\": 2" <<<"$(grep 02_ <<<"$out")"'

# store: 파일이 없으면 실패하고 아무것도 지우지 않는다
out="$(run store 2>&1 || true)"
check "받은 파일 없으면 store 실패" '[[ "$out" == *"없음: 01_"* ]]'

# pick: 상세 행이 있는 것만, movie·tv 반씩
out="$(INGEST_INPUT_DIR="$t/input" python3 -I "$root/scripts/ec2/ingest/csvtool.py" pick 4)"
check "pick 4 = movie 1·5, tv 2·4" '[ "$out" = "$(u 1)
$(u 5)
$(u 2)
$(u 4)" ]'
check "pick 홀수 거절" '! INGEST_INPUT_DIR="$t/input" python3 -I "$root/scripts/ec2/ingest/csvtool.py" pick 3 2>/dev/null'
check "pick 모자라면 실패" '! INGEST_INPUT_DIR="$t/input" python3 -I "$root/scripts/ec2/ingest/csvtool.py" pick 8 2>/dev/null'

# run sample: --content-id 4개, 1시간 제한, 이름표·비밀 참조
rm -f "$t/applied/"*
out="$(run run sample 4 2>&1)"
job_file="$t/applied/0.yaml"
check "sample Job 생성" '[[ "$out" == *"만듦: ingest-load-sample-"* ]]'
check "sample --content-id 4개" '[ "$(grep -c -- "- --content-id" "$job_file")" = 4 ]'
check "sample 제한 3600초" 'grep -q "activeDeadlineSeconds: 3600" "$job_file"'
check "Job에 남은 자리 없음" '[ -s "$job_file" ] && ! grep -v "^ *#" "$job_file" | grep -q "__"'
check "Job 이름 env와 metadata 일치" '[ "$(grep -c "ingest-load-sample-[0-9]\{12\}" "$job_file")" -ge 2 ]'
check "DB 비밀번호는 secretKeyRef" 'grep -q "name: ureka-ingest-db, key: DB_PASSWORD" "$job_file"'
check "Gemini 키는 secretKeyRef" 'grep -q "name: ureka-chat-ai, key: AI_API_KEY" "$job_file"'
check "DSN에 비밀번호 없음" '! grep -i "CONTENT_DB_DSN" -A1 "$job_file" | grep -qi password'
check "입력 PVC 읽기 전용" 'grep -q "claimName: ingest-input, readOnly: true" "$job_file"'
check "backoffLimit 0" 'grep -q "backoffLimit: 0" "$job_file"'

# run full: --content-id 없음, 14시간
rm -f "$t/applied/"*
run run full >/dev/null 2>&1
job_file="$t/applied/0.yaml"
check "full --content-id 없음" '[ -s "$job_file" ] && ! grep -q -- "- --content-id" "$job_file"'
check "full 제한 50400초" 'grep -q "activeDeadlineSeconds: 50400" "$job_file"'
check "full 인자 load-initial --with-embeddings" 'grep -A3 "^          args:" "$job_file" | grep -q -- "- --with-embeddings"'

# 실행 중 Job이 있으면 거절
out="$(FAKE_ACTIVE=ingest-load-full-202611181200 run run full 2>&1 || true)"
check "실행 중이면 run 거절" '[[ "$out" == *"이미 실행 중"* ]]'
check "잘못된 모드 거절" '! run run everything >/dev/null 2>&1'

# Job 이름 검사(파일 Pod sh -c에 들어가므로)
check "progress 이상한 이름 거절" '! run progress "x;rm -rf /" >/dev/null 2>&1'
check "quarantine 이상한 이름 거절" '! run quarantine "../etc" >/dev/null 2>&1'

# report: 확인 Pod를 띄우고 로그를 보여 준 뒤 지운다. Gemini 키는 받지 않는다.
rm -f "$t/applied/"*
out="$(run report 2>&1)"
report_file="$t/applied/0.yaml"
check "report 로그 출력" '[[ "$out" == *"[검색 가능 작품]"* ]]'
check "report Pod 정책 이름표 ingest-load" 'grep -q "app.kubernetes.io/name: ingest-load" "$report_file"'
check "report Pod에 Gemini 키 없음" '[ -s "$report_file" ] && ! grep -q "GEMINI_API_KEY\|ureka-chat-ai" "$report_file"'
check "report 뒤 Pod 삭제" 'grep -q "delete pod ingest-report" "$t/kubectl.log"'
check "report 실패는 실패로" '! FAKE_REPORT_PHASE=Failed run report >/dev/null 2>&1'

# quarantine 요약: 단계·오류 코드별
mkdir -p "$t/output/ingest-load-full-202611181200"
cat >"$t/output/ingest-load-full-202611181200/quarantine.jsonl" <<JSON
{"source": "01_공통_common_staging_v0_0_21.csv:content", "line": 3, "content_id": "$(u 3)", "error": "origin_country: 기준정보에 없는 country_code=ZZ"}
{"source": "01_공통_common_staging_v0_0_21.csv:embedding", "line": 4, "content_id": "$(u 4)", "error": "Gemini 임베딩 호출 실패: HTTP 429; 시도 3회", "error_code": "http_error", "http_status": 429, "attempts": 3}
{"source": "01_공통_common_staging_v0_0_21.csv:embedding", "line": 5, "content_id": "$(u 5)", "error": "Gemini 임베딩 호출 실패: HTTP 429; 시도 3회", "error_code": "http_error", "http_status": 429, "attempts": 3}
JSON
out="$(run quarantine ingest-load-full-202611181200 2>&1)"
check "격리 총 3건" '[[ "$out" == *"격리 총 3건"* ]]'
check "단계별 content 1·embedding 2" '[[ "$out" == *"'"'"'content'"'"': 1"* && "$out" == *"'"'"'embedding'"'"': 2"* ]]'
check "429 묶음 2건" '[[ "$out" == *"http_error HTTP 429 시도 3"*": 2"* ]]'

# recv.py: 127.0.0.1에서 세 파일 받고 끝남, 다른 경로 거절
port=$((20000 + RANDOM % 20000))
python3 -I "$root/scripts/ec2/ingest/recv.py" "$t/recv" "$port" >"$t/recv.log" 2>&1 &
rp=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/" >/dev/null 2>&1 && break || sleep 0.1; done
code="$(curl -s -o /dev/null -w '%{http_code}' -T "$t/02_movie_details_staging_v0_0_21.csv" "http://127.0.0.1:$port/../etc")"
check "recv 다른 경로 404" '[ "$code" = 404 ]'
for kind in common movie tv; do
  case $kind in common) f=01_공통_common_staging_v0_0_21.csv ;; movie) f=02_movie_details_staging_v0_0_21.csv ;; tv) f=03_tv_series_details_staging_v0_0_21.csv ;; esac
  curl -s -T "$t/$f" "http://127.0.0.1:$port/$kind" >"$t/recv-$kind.out"
done
wait "$rp" || true
check "recv 세 파일 받고 종료" 'grep -q "받은 파일: common, movie, tv" "$t/recv.log"'
check "recv 내용 같음" 'cmp -s "$t/03_tv_series_details_staging_v0_0_21.csv" "$t/recv/03_tv_series_details_staging_v0_0_21.csv"'
check "recv sha256 응답" 'grep -q "sha256 $(shasum -a 256 "$t/01_공통_common_staging_v0_0_21.csv" | cut -d" " -f1)" "$t/recv-common.out"'
check "recv 폴더 0700" '[ "$(stat -c %a "$t/recv" 2>/dev/null || stat -f %Lp "$t/recv")" = 700 ]'
check "recv 파일 0600" '[ "$(stat -c %a "$t/recv/02_movie_details_staging_v0_0_21.csv" 2>/dev/null || stat -f %Lp "$t/recv/02_movie_details_staging_v0_0_21.csv")" = 600 ]'

echo "통과 $pass / 실패 $fail"
[ "$fail" = 0 ]
