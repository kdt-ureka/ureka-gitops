"""Offline Helm checks. Run with helm on PATH and PyYAML installed."""
import json
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = 'charts/ureka-observability'
VALUES = 'environments/ec2/observability/values.yaml'

def render(extra=()):
    out = subprocess.check_output(['helm', 'template', 'test', CHART, '-n', 'observability', '-f', VALUES, *extra], cwd=ROOT, text=True)
    return [d for d in yaml.safe_load_all(out) if d]

def objects(items, kind):
    return [d for d in items if d['kind'] == kind]

class ObservabilityRendering(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.disabled = render()
        cls.enabled = render(('--set', 'appMetrics.enabled=true'))

    def test_missing_digest_refuses_install(self):
        p = subprocess.run(['helm', 'template', 'test', CHART], cwd=ROOT, capture_output=True)
        self.assertNotEqual(p.returncode, 0)

    def test_no_external_ui_or_privileged_workloads(self):
        for d in objects(self.enabled, 'Service'):
            self.assertEqual(d['spec']['type'], 'ClusterIP')
        self.assertFalse(objects(self.enabled, 'Ingress'))
        for d in objects(self.enabled, 'Deployment'):
            s = d['spec']['template']['spec']
            self.assertTrue(s['securityContext']['runAsNonRoot'])
            self.assertFalse(s.get('hostNetwork', False))
            for c in s['containers']:
                self.assertTrue(c['securityContext']['readOnlyRootFilesystem'])
                self.assertFalse(c['securityContext']['allowPrivilegeEscalation'])
                self.assertRegex(c['image'], r'@sha256:[a-f0-9]{64}$')
                self.assertFalse(any('hostPort' in p for p in c['ports']))
        graf = next(d for d in objects(self.enabled,'Deployment') if d['metadata']['name']=='obs-grafana')
        self.assertFalse(graf['spec']['template']['spec']['automountServiceAccountToken'])

    def test_kube_state_metrics_args_are_single_flags(self):
        # 쉼표가 든 값이 YAML 흐름 목록에서 두 인자로 갈라지면 컨테이너가 "unknown command"로 바로 종료된다.
        for items in (self.disabled, self.enabled):
            ksm = next(d for d in objects(items, 'Deployment') if d['metadata']['name'] == 'obs-kube-state-metrics')
            args = ksm['spec']['template']['spec']['containers'][0]['args']
            self.assertEqual(args, ['--resources=pods,nodes'])
            for d in objects(items, 'Deployment'):
                for c in d['spec']['template']['spec']['containers']:
                    for a in c.get('args', []):
                        self.assertTrue(a.startswith('--'), f"{d['metadata']['name']}: 플래그가 아닌 인자 {a!r}")

    def test_rbac_has_no_secret_write_or_kubelet_proxy(self):
        for d in objects(self.enabled, 'ClusterRole') + objects(self.enabled, 'Role'):
            for rule in d['rules']:
                self.assertTrue(set(rule['verbs']) <= {'get', 'list', 'watch'})
                self.assertFalse({'secrets', '*', 'nodes/proxy'} & set(rule['resources']))

    def test_disabled_apps_do_not_require_token_or_open_jvm_policy(self):
        p = next(d for d in objects(self.disabled, 'Deployment') if d['metadata']['name']=='obs-prometheus')
        self.assertFalse(any('secret' in v for v in p['spec']['template']['spec']['volumes']))
        self.assertFalse(any(d['metadata'].get('namespace')=='dev' for d in objects(self.disabled,'NetworkPolicy')))
        cfg = next(d for d in objects(self.disabled,'ConfigMap') if d['metadata']['name']=='obs-prometheus')
        self.assertEqual({j['job_name'] for j in yaml.safe_load(cfg['data']['prometheus.yml'])['scrape_configs']}, {'prometheus','kube-state-metrics','kubelet-cadvisor'})

    def test_metrics_policy_allows_only_prometheus_on_metrics_port(self):
        # dev 업무 연결(8080)은 dev 정책(environments/ec2/dev/networkpolicy)이 연다. 관측 정책이 dev 전체에 8080을 열면 #40 허용 표가 무너진다.
        cases = [
            (self.enabled, {'obs-auth-metrics': 9091, 'obs-content-metrics': 9091}),
            (render(('--set', 'appMetrics.enabled=true', '--set', 'appMetrics.chatEnabled=true')),
             {'obs-auth-metrics': 9091, 'obs-content-metrics': 9091, 'obs-chat-metrics': 8080}),
        ]
        for items, expected in cases:
            policies = {d['metadata']['name']: d for d in objects(items,'NetworkPolicy') if d['metadata'].get('namespace')=='dev'}
            self.assertEqual(set(policies), set(expected))
            for name, port in expected.items():
                rules = policies[name]['spec']['ingress']
                self.assertEqual(len(rules), 1, name)
                self.assertEqual(rules[0]['ports'], [{'protocol': 'TCP', 'port': port}], name)
                self.assertEqual(len(rules[0]['from']), 1, name)
                peer = rules[0]['from'][0]
                self.assertEqual(peer['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'],'observability')
                self.assertEqual(peer['podSelector']['matchLabels']['app.kubernetes.io/name'],'obs-prometheus')

    def test_scrape_tls_secret_files_labels_and_rules(self):
        cm=next(d for d in objects(self.enabled,'ConfigMap') if d['metadata']['name']=='obs-prometheus')
        cfg=yaml.safe_load(cm['data']['prometheus.yml']);jobs={j['job_name']:j for j in cfg['scrape_configs']}
        self.assertEqual(cfg['global']['scrape_interval'],'30s')
        self.assertFalse(jobs['kubelet-cadvisor']['tls_config'].get('insecure_skip_verify',False))
        self.assertEqual(jobs['kubelet-cadvisor']['metrics_path'],'/metrics/cadvisor')
        for service in ('auth','content'):
            j=jobs['ureka-'+service]
            self.assertEqual(j['http_headers']['X-Internal-Token']['files'], ['/etc/metrics-tokens/'+service])
            self.assertTrue({'namespace','pod'} <= {r.get('target_label') for r in j['relabel_configs']})
        self.assertNotIn('ureka-chat',jobs)
        enabled = render(('--set', 'appMetrics.enabled=true', '--set', 'appMetrics.chatEnabled=true'))
        cm_chat=next(d for d in objects(enabled,'ConfigMap') if d['metadata']['name']=='obs-prometheus')
        chat_jobs={j['job_name']:j for j in yaml.safe_load(cm_chat['data']['prometheus.yml'])['scrape_configs']}
        self.assertEqual(chat_jobs['ureka-chat']['metrics_path'],'/internal/v1/metrics')
        prom=next(d for d in objects(self.enabled,'Deployment') if d['metadata']['name']=='obs-prometheus')
        token_volume=next(v for v in prom['spec']['template']['spec']['volumes'] if v['name']=='tokens')
        self.assertEqual(token_volume['secret']['items'],[{'key':'auth','path':'auth'},{'key':'content','path':'content'}])
        self.assertFalse(cfg.get('alerting')) # rule evaluation is not notification delivery

    def test_resource_budget_and_persistent_storage(self):
        def mib(v):
            return int(v[:-2])*(1024 if v.endswith('Gi') else 1)
        containers=[d['spec']['template']['spec']['containers'][0] for d in objects(self.enabled,'Deployment')]
        self.assertEqual(sum(mib(c['resources']['limits']['memory']) for c in containers),1792)
        self.assertEqual(sum(mib(c['resources']['requests']['memory']) for c in containers),1024)
        pvcs=objects(self.enabled,'PersistentVolumeClaim');self.assertEqual(len(pvcs),2)
        self.assertEqual(sum(mib(d['spec']['resources']['requests']['storage']) for d in pvcs),6144)
        self.assertTrue(all('Prune=false' in d['metadata']['annotations']['argocd.argoproj.io/sync-options'] for d in pvcs))

    def test_dashboard_preserves_gaps_and_contains_core_panels(self):
        dash=json.loads((ROOT/CHART/'files/overview.json').read_text())
        queries='\n'.join(t['expr'] for p in dash['panels'] for t in p['targets'])
        for metric in ('container_cpu_usage_seconds_total','container_memory_working_set_bytes','kube_pod_container_status_restarts_total','jvm_memory_used_bytes','chat_worker_backlog'):
            self.assertIn(metric,queries)
        self.assertNotIn('or vector(0)',queries)
        self.assertTrue(all(not p['fieldConfig']['defaults']['custom']['spanNulls'] for p in dash['panels']))

    def test_app_flags_default_off_and_named_metrics_only_when_enabled(self):
        for name in ('auth','content'):
            cmd=['helm','template',name,'charts/ureka-backend','-f',f'environments/base/ureka-{name}.yaml','-f',f'environments/ec2/dev/ureka-{name}.yaml','--set','image.registry=registry.example.invalid']
            normal=list(yaml.safe_load_all(subprocess.check_output(cmd,cwd=ROOT,text=True)))
            enabled=list(yaml.safe_load_all(subprocess.check_output(cmd+['--set','metrics.enabled=true'],cwd=ROOT,text=True)))
            get=lambda docs:next(x for x in docs if x and x['kind']=='Deployment')['spec']['template']['spec']['containers'][0]
            before,after=get(normal),get(enabled)
            self.assertEqual(before['ports'],[{'name':'http','containerPort':8080}])
            self.assertIn({'name':'metrics','containerPort':9091},after['ports'])
            self.assertEqual(after['env'][:-2],before['env'])
            self.assertEqual(after['env'][-2],{'name':'SPRING_PROFILES_INCLUDE','value':'observability'})
            self.assertEqual(after['env'][-1],{'name':'METRICS_SCRAPE_TOKEN','valueFrom':{'secretKeyRef':{'name':f'ureka-{name}-metrics','key':'METRICS_SCRAPE_TOKEN'}}})
            self.assertEqual(before['readinessProbe'],after['readinessProbe'])

if __name__=='__main__':
    unittest.main()
