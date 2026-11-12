#!/usr/bin/env bash
# environments/*/ureka-*.yaml 각각으로 charts/ureka-backend를 lint·렌더링한다.
# worker values는 본 서비스 values와 image·env가 같은지 비교한다(yq).
# environments/*/data(kustomize: DB·Redis)도 렌더링한다. 이미지가 digest(sha256)로 고정됐는지 모두 확인한다.
# CI(Helm 워크플로)와 로컬에서 같이 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."

helm version --short
status=0
for values in environments/*/ureka-*.yaml; do
  echo "== ${values}"
  helm lint charts/ureka-backend -f "$values" --strict >/dev/null || { echo "::error file=${values}::helm lint 실패"; status=1; continue; }
  rendered="$(helm template check charts/ureka-backend -f "$values")" || { echo "::error file=${values}::렌더링 실패"; status=1; continue; }
  # 마이그레이션 Job이 있으면 image 줄이 여러 개다. 모두 확인한다.
  while read -r image; do
    if ! [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      echo "::error file=${values}::이미지가 digest로 고정되지 않았다: ${image}"
      status=1
    fi
    echo "image: ${image}"
  done < <(printf '%s\n' "$rendered" | sed -n 's/^ *image: *//p' | sort -u)
done
# 같은 이미지로 띄우는 worker(ureka-<서비스>-worker.yaml)는 본 서비스 values와 image·env가 같아야 한다.
for worker in environments/*/ureka-*-worker.yaml; do
  [ -f "$worker" ] || continue
  base="${worker%-worker.yaml}.yaml"
  echo "== ${worker} ↔ ${base} (image·env 비교)"
  for key in .image .env; do
    if [ "$(yq -o=json "$key" "$worker")" != "$(yq -o=json "$key" "$base")" ]; then
      echo "::error file=${worker}::${key}가 ${base}와 다르다"
      status=1
    fi
  done
done
for dir in environments/*/data; do
  [ -f "${dir}/kustomization.yaml" ] || continue
  echo "== ${dir} (kustomize)"
  rendered="$(kubectl kustomize "$dir")" || { echo "::error file=${dir}::kustomize 렌더링 실패"; status=1; continue; }
  while read -r image; do
    if ! [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
      echo "::error file=${dir}::이미지가 digest로 고정되지 않았다: ${image}"
      status=1
    fi
    echo "image: ${image}"
  done < <(printf '%s\n' "$rendered" | sed -n 's/^ *image: *//p' | sort -u)
done
exit "$status"
