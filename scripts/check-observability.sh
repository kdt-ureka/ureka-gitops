#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v helm >/dev/null
promtool="${PROMTOOL:-promtool}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
helm lint charts/ureka-observability --strict -f environments/ec2/observability/values.yaml
helm template obs charts/ureka-observability -n observability \
  -f environments/ec2/observability/values.yaml --set appMetrics.enabled=true > "$work/manifest.yaml"
python3 -m unittest discover -s tests/observability -v
python3 - "$work" <<'PY'
import json,pathlib,sys,yaml
root=pathlib.Path(sys.argv[1]);docs=list(yaml.safe_load_all((root/'manifest.yaml').read_text()))
cm=next(d for d in docs if d and d['kind']=='ConfigMap' and d['metadata']['name']=='obs-prometheus')['data']
for name,content in cm.items():
 if name=='prometheus.yml':
  c=yaml.safe_load(content);c['rule_files']=[str(root/'rules.yml')]
  # 오프라인 검사에 필요한 경로만 임시 placeholder로 치환; 실제 토큰/클러스터 접근 없음.
  for job in c['scrape_configs']:
   if 'authorization' in job:job['authorization']['credentials_file']=str(root/'token')
   if 'tls_config' in job:job['tls_config']['ca_file']='/etc/ssl/certs/ca-certificates.crt'
   for h in job.get('http_headers',{}).values():
    if 'files' in h:h['files']=[str(root/'token')]
  content=yaml.safe_dump(c)
 (root/name).write_text(content)
(root/'token').write_text('offline-placeholder')
# 대시보드의 모든 쿼리도 PromQL 문법 검사. Grafana 변수는 정규식으로 대체.
d=json.loads(pathlib.Path('charts/ureka-observability/files/overview.json').read_text())
rules=[{'record':f'query_check_{i}','expr':t['expr'].replace('$namespace','.*').replace('$pod','.*')} for i,t in enumerate(t for p in d['panels'] for t in p['targets'])]
(root/'queries.yml').write_text(yaml.safe_dump({'groups':[{'name':'queries','rules':rules}]}))
PY
"$promtool" check config --syntax-only "$work/prometheus.yml"
"$promtool" check rules "$work/rules.yml" "$work/queries.yml"
(cd tests/observability && "$promtool" test rules rules-test.yml)
