"""EKS #49 renders and independent matrices; no AWS/kubectl cluster calls."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "networkpolicy"))

import check_matrix as cm
import probe_compare as pc

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("probe_eks", ROOT / "scripts/netpol/probe_eks.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def render(env, *, alb=False, metrics=False, cidrs=None):
    args = ['helm', 'template', 'netpol', 'charts/ureka-networkpolicy', '-n', env,
            '-f', f'environments/eks/{env}/networkpolicy/values.yaml', '--set', f'alb.enabled={str(alb).lower()}',
            '--set', f'metrics.enabled={str(metrics).lower()}', '--set', f'metrics.chatEnabled={str(metrics).lower()}']
    for i, cidr in enumerate(cidrs or []):
        args += ['--set-string', f'alb.sourceCidrs[{i}]={cidr}']
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr)
    return decode(result.stdout)


def decode(yaml):
    result = subprocess.check_output(['yq', 'ea', '-o=json', '-I=0', 'select(. != null)', '-'], input=yaml, text=True)
    return [json.loads(x) for x in result.splitlines() if x and x != '---']


def mismatches(exp, policies, scenario):
    cm.validate(policies, allow_ipblock=True)
    want = {tuple(x) for x in exp['allow'][scenario]}
    return [(src, target, port) for src, source in exp['sources'].items() for target, ports in exp['targets'].items()
            for port in ports if cm.allowed(policies, source, {'app.kubernetes.io/name': target}, port, exp['namespace'])
            != ((src, target, port) in want)]


class EksPolicy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exp = {e: json.loads((ROOT / f'tests/networkpolicy/eks-{e}.json').read_text()) for e in ['dev', 'prod']}
        cls.renders = {}
        for env, exp in cls.exp.items():
            for scenario in exp['allow']:
                cls.renders[env, scenario] = render(env, alb='alb' in scenario, metrics='metrics' in scenario,
                                                   cidrs=['10.240.0.0/24'] if 'alb' in scenario else [])

    def test_all_scenarios_match_independent_tables(self):
        for (env, scenario), docs in self.renders.items():
            with self.subTest(env=env, scenario=scenario):
                self.assertEqual(mismatches(self.exp[env], docs, scenario), [])
                count = sum(len(p) for p in self.exp[env]['targets'].values()) * len(self.exp[env]['sources'])
                print(f'{env}/{scenario}: {count} static combinations, allow {len(self.exp[env]["allow"][scenario])}')

    def test_default_deny_and_only_ingress(self):
        for (env, scenario), docs in self.renders.items():
            self.assertEqual(sum(d['spec']['podSelector'] == {} and d['spec']['ingress'] == [] for d in docs), 1)
            for d in docs:
                self.assertEqual(d['kind'], 'NetworkPolicy')
                self.assertEqual(d['metadata']['namespace'], env)
                self.assertEqual(d['spec']['policyTypes'], ['Ingress'])

    def test_alb_only_five_public_targets_tcp8080(self):
        docs = self.renders['prod', 'alb']
        alb = [d for d in docs if d['metadata']['name'].startswith('alb-')]
        self.assertEqual({d['spec']['podSelector']['matchLabels']['app.kubernetes.io/name'] for d in alb},
                         {'ureka-frontend', 'ureka-auth', 'ureka-chat', 'ureka-content', 'ureka-ops'})
        for d in alb:
            self.assertEqual(d['spec']['ingress'][0]['ports'], [{'protocol': 'TCP', 'port': 8080}])
            self.assertEqual(d['spec']['ingress'][0]['from'], [{'ipBlock': {'cidr': '10.240.0.0/24'}}])

    def test_missing_bad_or_broad_alb_sources_fail(self):
        for cidrs in [[], ['0.0.0.0/0'], ['10.0.0.0/8'], ['192.0.2.0/24'], ['10.999.0.0/24'],
                      ['10.1.0.0/33'], ['::/0'], ['invalid'], ['10.1.0.0/24'] * 9]:
            with self.subTest(cidrs=cidrs), self.assertRaises(ValueError):
                render('prod', alb=True, cidrs=cidrs)
        with self.assertRaises(ValueError):
            render('dev', alb=True, cidrs=['10.240.0.0/24'])
        with self.assertRaises(ValueError):
            render('default')

    def test_no_default_deny_or_extra_allow_is_detected(self):
        for env in ['dev', 'prod']:
            policies = self.renders[env, 'baseline']
            self.assertTrue(mismatches(self.exp[env], policies[1:], 'baseline'))
            wide = {'kind': 'NetworkPolicy', 'metadata': {'name': 'bad', 'namespace': env},
                    'spec': {'podSelector': {}, 'policyTypes': ['Ingress'], 'ingress': [{}]}}
            self.assertTrue(mismatches(self.exp[env], policies + [wide], 'baseline'))
            self.assertTrue(mismatches(self.exp[env], policies[:1], 'baseline'))

    def test_monitoring_namespace_and_pod_are_both_required(self):
        docs = copy.deepcopy(self.renders['prod', 'metrics'])
        policy = next(d for d in docs if d['metadata']['name'] == 'metrics-ureka-auth')
        peer = policy['spec']['ingress'][0]['from'][0]
        policy['spec']['ingress'][0]['from'] = [{'namespaceSelector': peer['namespaceSelector']},
                                               {'podSelector': peer['podSelector']}]
        self.assertTrue(mismatches(self.exp['prod'], docs, 'metrics'))

    def test_ipblock_except_and_cross_namespace(self):
        docs = copy.deepcopy(self.renders['prod', 'alb'])
        target = next(d for d in docs if d['metadata']['name'] == 'alb-ureka-auth')
        target['spec']['ingress'][0]['from'][0]['ipBlock']['except'] = ['10.240.0.10/32']
        cm.validate(docs, allow_ipblock=True)
        self.assertFalse(cm.allowed(docs, self.exp['prod']['sources']['external/alb-subnet'],
                                   {'app.kubernetes.io/name': 'ureka-auth'}, 8080, 'prod'))
        target['spec']['ingress'][0]['from'][0]['ipBlock']['except'] = ['192.0.2.0/24']
        with self.assertRaises(cm.Unsupported):
            cm.validate(docs, allow_ipblock=True)

    def test_root_app_scope_and_manual_prod_sync(self):
        raw = subprocess.check_output(['helm', 'template', 'root', 'argocd/eks/apps', '--set',
                                      'ecrRegistry=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com'], cwd=ROOT, text=True)
        docs = decode(raw)
        for env in ['dev', 'prod']:
            app = next(d for d in docs if d['metadata']['name'] == f'ureka-eks-networkpolicy-{env}')
            self.assertEqual(app['spec']['project'], f'ureka-eks-{env}')
            self.assertEqual(app['metadata']['annotations']['argocd.argoproj.io/sync-wave'], '-1')
            self.assertEqual(app['spec']['destination']['namespace'], env)
            self.assertEqual('automated' in app['spec']['syncPolicy'], env == 'dev')
            self.assertEqual(next(p['value'] for p in app['spec']['source']['helm']['parameters'] if p['name'] == 'alb.enabled'), 'false')
            proj = next(d for d in docs if d['kind'] == 'AppProject' and d['metadata']['name'] == f'ureka-eks-{env}')
            self.assertIn({'group': 'networking.k8s.io', 'kind': 'NetworkPolicy'}, proj['spec']['namespaceResourceWhitelist'])

    def test_probe_uses_deployment_never_a_ready_service_endpoint(self):
        table = probe.probe_table(self.exp['prod'])
        self.assertFalse(any(s.get('external') for s in table['sources'].values()))
        source = self.exp['prod']['sources']['prod/ureka-auth']
        dep = probe.deployment(source, 'synthetic:test', 'probe-test', 'run')
        self.assertEqual(dep['kind'], 'Deployment')
        pod = dep['spec']['template']
        self.assertEqual(pod['metadata']['labels']['app.kubernetes.io/name'], 'ureka-auth')
        self.assertNotIn('app.kubernetes.io/instance', pod['metadata']['labels'])
        self.assertIn('raise SystemExit(1)', pod['spec']['containers'][0]['readinessProbe']['exec']['command'])
        self.assertFalse(pod['spec']['automountServiceAccountToken'])

    def test_endpoint_gate_requires_exact_pod_and_ingress(self):
        pod = {'metadata': {'name': 'auth-candidate', 'namespace': 'prod'}, 'status': {'podIP': '10.241.0.10'}}
        endpoint = {'podIP': '10.241.0.10', 'name': 'auth-candidate', 'namespace': 'prod'}
        data = {'items': [{'spec': {'podIsolation': ['Ingress'], 'podSelectorEndpoints': [endpoint]}}]}
        self.assertTrue(probe.endpoint_contains(data, pod))
        self.assertFalse(probe.endpoint_contains({'items': []}, pod))
        data['items'][0]['spec']['podIsolation'] = ['Egress']
        self.assertFalse(probe.endpoint_contains(data, pod))

    def test_non_cumulative_probe_scenarios_and_missing_rows_fail(self):
        table = probe.probe_table(self.exp['prod'])
        targets = ['ureka-auth:8080']
        allowed = {tuple(r) for r in table['allow']['baseline']}
        lines = [f'{src} ureka-auth:8080 {"허용" if (src, "ureka-auth", 8080) in allowed else "차단"}'
                 for src in table['sources']]
        self.assertEqual(pc.compare(table, 'baseline', targets, lines, 0)[0], [])
        self.assertTrue(pc.compare(table, 'baseline', targets, lines[:-1], 0)[0])
        self.assertTrue(pc.compare(table, 'baseline', targets, lines, 1)[0])


if __name__ == '__main__':
    unittest.main()
