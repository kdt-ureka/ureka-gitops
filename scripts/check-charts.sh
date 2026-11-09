#!/usr/bin/env bash
# environments/*/ureka-*.yaml 각각으로 charts/ureka-backend를 lint·렌더링한다.
# 이미지가 digest(sha256)로 고정됐는지도 확인한다. CI(Helm 워크플로)와 로컬에서 같이 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."

helm version --short
status=0
for values in environments/*/ureka-*.yaml; do
  echo "== ${values}"
  helm lint charts/ureka-backend -f "$values" --strict >/dev/null || { echo "::error file=${values}::helm lint 실패"; status=1; continue; }
  rendered="$(helm template check charts/ureka-backend -f "$values")" || { echo "::error file=${values}::렌더링 실패"; status=1; continue; }
  image="$(printf '%s\n' "$rendered" | sed -n 's/^ *image: *//p')"
  if ! [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "::error file=${values}::이미지가 digest로 고정되지 않았다: ${image}"
    status=1
  fi
  echo "image: ${image}"
done
exit "$status"
