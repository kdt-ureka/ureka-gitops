"""Fake API integration for the EKS runner: no cluster connection or namespace mutation."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('eks_probe', ROOT / 'scripts/netpol/probe_eks.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
spec = importlib.util.spec_from_file_location('alb_patch', ROOT / 'scripts/netpol/alb-root-patch.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


class Fake(p.Runner):
    def __init__(self):
        super().__init__(SimpleNamespace(context='synthetic-context', namespace='prod', keep=False,
                         expected=ROOT / 'tests/networkpolicy/eks-prod.json', scenario='baseline',
                         targets='ureka-auth:8080 redis:6379'))
        self.calls = []
        self.table = p.probe_table(json.loads(self.args.expected.read_text()))
        self.source_index = -1
        self.current = None
        self.endpoint_missing = False
        self.exec_failure = False
        self.publish_not_ready = False

    def pod(self, name, ns='prod'):
        return {'metadata': {'name': name, 'namespace': ns}, 'status': {'podIP': '10.241.0.10', 'phase': 'Running',
            'conditions': [{'type': 'Ready', 'status': 'True'}], 'containerStatuses': [{'state': {'running': {}}}]}}

    def get(self, *args, optional=False):
        resource = args[0]
        if resource == 'namespace':
            return {'metadata': {'name': args[1]}}
        if resource == 'service':
            return {'items': [{'spec': {'publishNotReadyAddresses': True, 'selector': {'app.kubernetes.io/name': 'ureka-auth'}}}]} if self.publish_not_ready else {'items': []}
        if resource == 'deployment':
            return {'spec': {'template': {'spec': {'containers': [{'image': 'synthetic:test'}]}}}}
        if resource == 'pod':
            if any('probe-source=' in x for x in args):
                # Readiness intentionally false; containers are Running and exec is available.
                pod = self.pod(self.current['metadata']['name'], self.current['metadata']['namespace'])
                pod['status']['conditions'][0]['status'] = 'False'
                pod['status']['containerStatuses'][0]['state']['running'] = {'startedAt': 'synthetic'}
                return {'items': [pod]}
            # Two Ready replicas must both be tested.
            return {'items': [self.pod('target-stable'), self.pod('target-candidate')]}
        if resource == 'policyendpoints.networking.k8s.aws':
            return {'items': []} if self.endpoint_missing else {'items': [{'spec': {'podIsolation': ['Ingress'], 'podSelectorEndpoints': [
                {'name': n, 'namespace': 'prod', 'podIP': '10.241.0.10'} for n in ['target-stable', 'target-candidate']]}}]}
        raise AssertionError(args)

    def k(self, *args, payload=None, optional=False):
        self.calls.append((args, payload))
        if args[0] == 'create':
            self.source_index += 1
            self.current = payload
            return ''
        if 'exec' in args:
            if self.exec_failure:
                raise RuntimeError('synthetic exec failure')
            pairs = args[args.index(p.CHECKER) + 1:]
            source = list(self.table['sources'])[self.source_index]
            allowed = {tuple(row) for row in self.table['allow']['baseline']}
            return '\n'.join(f'{name}:{port} {"허용" if (source, name, int(port)) in allowed else "차단"}'
                             for name, port, ip in (pair.split(':') for pair in pairs))
        return ''


class ProbeIntegration(unittest.TestCase):
    def execute(self, runner):
        with patch.object(p.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            runner.execute()

    def test_complete_matrix_two_replicas_pass_and_only_owned_deployments_deleted(self):
        runner = Fake()
        self.execute(runner)
        self.assertEqual(len([x for x in runner.calls if x[0][0] == 'create']), len(runner.table['sources']))
        self.assertEqual(runner.created, [])
        self.assertTrue(all('deployment' in args and '--wait=true' in args for args, payload in runner.calls if 'delete' in args))
        self.assertFalse(any(payload and payload.get('kind') == 'Namespace' for args, payload in runner.calls))

    def test_missing_endpoint_or_unsafe_service_fails_before_create(self):
        for field in ['endpoint_missing', 'publish_not_ready']:
            runner = Fake()
            setattr(runner, field, True)
            with self.assertRaises(RuntimeError):
                self.execute(runner)
            self.assertFalse(any(args[0] == 'create' for args, payload in runner.calls))

    def test_exec_failure_does_not_pass_and_cleanup_only_own_run(self):
        runner = Fake()
        runner.exec_failure = True
        with self.assertRaises(RuntimeError):
            self.execute(runner)
        self.assertEqual(len(runner.created), 1)
        ns, name = runner.created[0]
        runner.cleanup()
        self.assertEqual(runner.calls[-1][0][:5], ('-n', ns, 'delete', 'deployment', name))
        self.assertTrue(name.startswith('probe-' + runner.run_id))

    def test_empty_selected_targets_fail_before_mutation(self):
        runner = Fake()
        runner.args.targets = ''
        with self.assertRaises(RuntimeError):
            self.execute(runner)
        self.assertFalse(runner.calls)

    def test_root_patch_validates_and_preserves_other_parameters(self):
        result = a.patch(['10.240.0.0/24', '10.240.1.0/24'])
        self.assertEqual(len(result), 3)
        self.assertTrue(all(r['path'] == '/spec/source/helm/parameters/-' for r in result))
        self.assertTrue(all(r['value']['name'].startswith('networkPolicy.alb.') for r in result))
        for bad in [[], ['0.0.0.0/0'], ['10.0.0.0/8'], ['192.0.2.0/24'], ['10.240.0.1/24'],
                    ['10.240.0.0/24'] * 2, ['::/0']]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                a.patch(bad)


if __name__ == '__main__':
    unittest.main()
