#!/usr/bin/env bash
# environments/*/ureka-*.yaml 각각으로 charts/ureka-backend를 lint·렌더링한다(kind 등 한 겹 values).
# 두 겹 values(environments/base + environments/ec2/<환경>)는 겹쳐서 렌더링하고, 레지스트리 주입 없이는 실패하는지도 본다.
# root 앱 차트(argocd/ec2/apps)가 만드는 Application이 가리키는 values 파일이 모두 있는지 본다.
# worker values는 본 서비스 values와 image·env가 같은지 비교한다(yq).
# environments/*/data(kustomize: DB·Redis)도 렌더링한다. 이미지가 digest(sha256)로 고정됐는지 모두 확인한다.
# CI(Helm 워크플로)와 로컬에서 같이 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."

helm version --short
status=0
for values in environments/*/ureka-*.yaml; do
  # base는 혼자 쓰지 않는다(아래 두 겹 검사에서 환경 values와 겹쳐 본다).
  case "$values" in environments/base/*) continue ;; esac
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
for worker in environments/*/ureka-*-worker.yaml environments/ec2/*/ureka-*-worker.yaml; do
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
for dir in environments/*/data environments/ec2/*/data; do
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
  # ExternalName(EC2: Service postgres → RDS)은 실제 RDS 엔드포인트여야 한다(자리표시·다른 주소면 실패).
  while read -r ext; do
    [ -n "$ext" ] || continue
    if ! [[ "$ext" =~ ^[a-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws\.com$ ]]; then
      echo "::error file=${dir}::ExternalName이 RDS 엔드포인트가 아니다(apply 뒤 terraform output -raw endpoint로 채운다): ${ext}"
      status=1
    fi
    echo "externalName: ${ext}"
  done < <(printf '%s\n' "$rendered" | yq ea 'select(.kind == "Service" and .spec.type == "ExternalName") | .spec.externalName' - | grep -v '^---$' || true)
  # EC2 data에는 PostgreSQL을 클러스터 안에 띄우는 StatefulSet·PostSync 계정 Job이 없어야 한다(마스터 비밀번호 상시 보관 방지).
  case "$dir" in environments/ec2/*)
    if printf '%s\n' "$rendered" | yq ea 'select(.kind == "StatefulSet" or .kind == "Job") | .metadata.name' - | grep -qv '^---$'; then
      echo "::error file=${dir}::EC2 data에 StatefulSet·Job이 있다(RDS 계정 Job은 scripts/ec2/rds-bootstrap.sh만 만든다)"
      status=1
    fi ;;
  esac
done
# 두 겹 values: base → environments/ec2/<환경>. 시험용 레지스트리(예시 계정 ID)를 넣어 렌더링한다.
test_registry=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com
for envdir in environments/ec2/*/; do
  envdir="${envdir%/}"
  ls "$envdir"/ureka-*.yaml >/dev/null 2>&1 || continue
  # 환경마다 base의 서비스가 모두 있고, base에 없는 서비스는 없어야 한다.
  for b in environments/base/ureka-*.yaml; do
    [ -f "${envdir}/$(basename "$b")" ] || { echo "::error file=${b}::${envdir}에 같은 이름 values가 없다"; status=1; }
  done
  for values in "$envdir"/ureka-*.yaml; do
    base="environments/base/$(basename "$values")"
    echo "== ${base} + ${values}"
    [ -f "$base" ] || { echo "::error file=${values}::${base}가 없다"; status=1; continue; }
    layered=(-f "$base" -f "$values")
    if helm template check charts/ureka-backend "${layered[@]}" >/dev/null 2>&1; then
      echo "::error file=${values}::레지스트리 주입 없이 렌더링됐다(image.requireRegistry=true여야 한다)"; status=1
    fi
    helm lint charts/ureka-backend "${layered[@]}" --set "image.registry=${test_registry}" --strict >/dev/null ||
      { echo "::error file=${values}::helm lint 실패"; status=1; continue; }
    rendered="$(helm template check charts/ureka-backend "${layered[@]}" --set "image.registry=${test_registry}")" ||
      { echo "::error file=${values}::렌더링 실패"; status=1; continue; }
    while read -r image; do
      if ! [[ "$image" =~ ^${test_registry//./\\.}/ureka/[a-z-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]]; then
        echo "::error file=${values}::이미지가 주입한 레지스트리 + digest가 아니다: ${image}"
        status=1
      fi
      echo "image: ${image}"
    done < <(printf '%s\n' "$rendered" | sed -n 's/^ *image: *//p' | sort -u)
  done
done

# root 앱 차트: 레지스트리 없이는 실패, 넣으면 Application이 가리키는 values·경로가 모두 있어야 한다.
for apps in argocd/ec2/apps; do
  echo "== ${apps}"
  if helm template root "$apps" >/dev/null 2>&1; then
    echo "::error file=${apps}::ecrRegistry 없이 렌더링됐다"; status=1
  fi
  helm lint "$apps" --strict --set "ecrRegistry=${test_registry}" >/dev/null || { echo "::error file=${apps}::helm lint 실패"; status=1; continue; }
  rendered="$(helm template root "$apps" --set "ecrRegistry=${test_registry}")" || { echo "::error file=${apps}::렌더링 실패"; status=1; continue; }
  while read -r ref; do
    [ -e "$ref" ] || { echo "::error file=${apps}::없는 경로를 가리킨다: ${ref}"; status=1; }
  done < <(printf '%s\n' "$rendered" | yq ea '.spec.sources[]?.helm.valueFiles[], .spec.source.path // ""' - |
    grep -v -e '^---$' -e '^$' | sed 's#^\.\./\.\./##' | sort -u)
  echo "applications: $(printf '%s\n' "$rendered" | yq ea '[.metadata.name] | join(" ")' -)"
done
exit "$status"
