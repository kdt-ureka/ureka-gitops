#!/usr/bin/env bash
# EC2 dev 들어오는 연결 정책(#39·#40) 정적 시험. 클러스터 없이 돈다(CI Helm 워크플로와 로컬 공통).
# 1) 정책을 계산해 허용 표(tests/networkpolicy/expected.json)와 모든 (보내는 쪽 × 받는 쪽 × 포트) 조합이 같은지 본다.
#    dev에 함께 있는 정책(ingest Job 정책, 관측 차트의 지표 포트 정책)도 합쳐서 본다(정책은 합집합이다).
# 2) 형식: dev 네임스페이스, Ingress만(egress는 이번 범위 밖), 기본 거부가 있고 허용과 같은 kustomization에 있다.
# 3) root 앱이 정책 Application을 만들고(경로·wave·finalizer), 경로가 kustomization을 가리킨다.
# 4) 시험이 헛돌지 않는지: 허용 파일을 빼거나(=#39만 병합) 넓은 허용을 넣으면 실패해야 한다.
# 5) 계산기(check_matrix)·실측 결과 비교기(probe_compare) 단위 시험.
# 실제 차단 여부(CNI)는 이 시험이 대신하지 않는다: docs/ec2-networkpolicy.md의 kind·EC2 시험을 본다.
set -euo pipefail
cd "$(dirname "$0")/.."

dir=environments/ec2/dev/networkpolicy
expected=tests/networkpolicy/expected.json
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0
err() { echo "::error::$*"; status=1; }

to_json() { yq ea -o=json -I=0 'select(.kind == "NetworkPolicy")' - ; }

kubectl kustomize "$dir" | to_json > "$work/dev.json"
to_json < environments/ec2/dev/ingest/networkpolicy.yaml > "$work/ingest.json"
obs=(helm template obs charts/ureka-observability -n observability -f environments/ec2/observability/values.yaml)
"${obs[@]}" | to_json > "$work/obs-off.json"
"${obs[@]}" --set appMetrics.enabled=true --set appMetrics.chatEnabled=true | to_json > "$work/obs-on.json"

echo "== 계산기·실측 비교기 단위 시험(NetworkPolicy 의미, 누락·중복·실행 실패는 실패)"
python3 -m unittest discover -s tests/networkpolicy -p 'test_*.py' || status=1

echo "== 허용 표와 계산 결과 비교"
python3 tests/networkpolicy/check_matrix.py "$expected" "기본(관측 꺼짐)" "$work/dev.json" "$work/ingest.json" "$work/obs-off.json" || status=1
python3 tests/networkpolicy/check_matrix.py "$expected" "관측 켬(appMetrics.enabled·chatEnabled) 때 추가" "$work/dev.json" "$work/ingest.json" "$work/obs-on.json" || status=1

echo "== 형식"
[ "$(yq ea -I=0 -o=json '[.metadata.namespace] | unique' "$work/dev.json")" = '["dev"]' ] || err "dev 네임스페이스가 아닌 정책이 있다"
[ "$(yq ea -I=0 -o=json '[.spec.policyTypes] | unique' "$work/dev.json")" = '[["Ingress"]]' ] || err "policyTypes가 [Ingress]가 아닌 정책이 있다(egress는 이번 범위 밖)"
deny="$(yq ea -I=0 -o=json 'select((.spec.podSelector | length) == 0 and (.spec.ingress | length) == 0) | .metadata.name' "$work/dev.json")"
[ "$deny" = '"dev-default-deny-ingress"' ] || err "기본 거부 정책(podSelector {}, ingress [])이 정확히 하나여야 한다: ${deny:-없음}"
[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = '["default-deny-ingress.yaml","allow-ingress.yaml"]' ] ||
  err "kustomization에 기본 거부와 허용이 같이 있어야 한다(#39만 배포 금지)"
# 허용 규칙에 ipBlock·빈 from(모두 허용)·빈 ports(모든 포트)가 없어야 한다.
wide="$(yq ea -I=0 'select(.spec.ingress != null) | .spec.ingress[] | select(.from == null or .from == [] or .ports == null or .ports == [] or (.from[] | has("ipBlock"))) | path' "$work/dev.json" || true)"
[ -z "$wide" ] || err "넓은 허용 규칙(from·ports 비어 있음 또는 ipBlock)이 있다"

echo "== root 앱이 정책 Application을 만든다"
rendered="$(helm template root argocd/ec2/apps --set ecrRegistry=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com)"
app="$(printf '%s\n' "$rendered" | yq ea -o=json -I=0 'select(.kind == "Application" and .metadata.name == "ureka-dev-networkpolicy-ec2-dev")' -)"
[ -n "$app" ] || err "Application ureka-dev-networkpolicy-ec2-dev가 없다"
if [ -n "$app" ]; then
  [ "$(printf '%s' "$app" | yq -p=json '.spec.source.path')" = "$dir" ] || err "Application 경로가 ${dir}이 아니다"
  [ "$(printf '%s' "$app" | yq -p=json '.metadata.annotations["argocd.argoproj.io/sync-wave"]')" = "-1" ] || err "정책은 서비스(wave 0)보다 먼저(wave -1)여야 한다"
  [ "$(printf '%s' "$app" | yq -p=json '.metadata.finalizers[0]')" = "resources-finalizer.argocd.argoproj.io" ] ||
    err "finalizer가 없으면 Application을 지워도 정책이 남는다"
  [ "$(printf '%s' "$app" | yq -p=json '.spec.syncPolicy.automated.selfHeal')" = "true" ] || err "손으로 바꾼 정책을 Git 상태로 되돌려야 한다(selfHeal)"
fi

echo "== 시험이 헛돌지 않는지(일부러 틀린 정책은 실패해야 한다)"
# a) #39만 병합: 허용이 하나도 없으면 실패
yq ea -o=json -I=0 'select(.metadata.name == "dev-default-deny-ingress")' "$work/dev.json" > "$work/deny-only.json"
if python3 tests/networkpolicy/check_matrix.py "$expected" "기본(관측 꺼짐)" "$work/deny-only.json" "$work/ingest.json" "$work/obs-off.json" >/dev/null 2>&1; then
  err "기본 거부만 있어도 통과했다(시험이 허용을 확인하지 않는다)"
fi
# b) dev 전체에 auth 8080을 여는 정책이 섞이면 실패(이 PR 전 관측 정책이 하던 형태)
cat > "$work/wide.json" <<'JSON'
{"kind":"NetworkPolicy","metadata":{"name":"wide","namespace":"dev"},"spec":{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"ureka-auth"}},"policyTypes":["Ingress"],"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"dev"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}
JSON
if python3 tests/networkpolicy/check_matrix.py "$expected" "기본(관측 꺼짐)" "$work/dev.json" "$work/ingest.json" "$work/obs-off.json" "$work/wide.json" >/dev/null 2>&1; then
  err "dev 전체 허용 정책이 섞여도 통과했다(차단을 확인하지 않는다)"
fi
# c) 기본 거부가 빠지면(허용만) 정책이 없는 Pod(예: recommend 9091 없음 → ops 등)가 열려 실패
yq ea -o=json -I=0 'select(.metadata.name != "dev-default-deny-ingress")' "$work/dev.json" > "$work/allow-only.json"
if python3 tests/networkpolicy/check_matrix.py "$expected" "기본(관측 꺼짐)" "$work/allow-only.json" "$work/ingest.json" "$work/obs-off.json" >/dev/null 2>&1; then
  err "기본 거부가 없어도 통과했다"
fi

[ "$status" -eq 0 ] && echo "OK"
exit "$status"
