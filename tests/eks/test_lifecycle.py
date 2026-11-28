"""Offline checkpoint tests. Real AWS/kubectl read-only smoke is explicitly opt-in.

No AWS/cluster call was authorized for #102 implementation. The optional smoke is
for the operator's first approved recreation; it is NOT claimed as executed here.
A real local CLI --help test below checks argparse compatibility without connecting.
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/eks'))
import lifecycle as lc
from operate import SafeError


def args(direction='up', execute=None):
    return argparse.Namespace(direction=direction, execute=execute, profile='test',
        expected_account_id='123456789012', cluster_name='ureka-eks', context='ureka-eks',
        confirm_cluster=None, confirm_env=None, review_dir=None, confirm=None,
        confirm_cleanup=None, confirm_residue=None, verify_existing=False)


class Fake:
    def __init__(self, complete=(), fail=None):
        self.complete, self.fail = set(complete), fail
        self.calls, self.executions = [], []
        self.binding_value = 'a' * 64
        self.present = True

    def identity(self):
        pass

    def destination(self):
        return {}

    def binding(self):
        return self.binding_value

    def cluster(self):
        return {} if self.present else None

    def check(self, key, state):
        self.calls.append(key)
        if key == self.fail:
            raise SafeError('sensitive 123456789012 203.0.113.8 TOKEN')
        return key in self.complete

    def execute(self, step, state):
        self.executions.append(step.key)
        self.complete.add(step.key)

    def prepare_down_step(self, key, state):
        self.executions.append(key)
        if key != 'data-removed':
            self.complete.add(key)


class Workflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'up-20261124/state.json'
        self.shared = patch.object(lc, 'shared_lock_root', return_value=Path(self.tmp.name) / 'shared')
        self.shared.start()
        self.output = io.StringIO()
        self.capture = contextlib.redirect_stdout(self.output)
        self.capture.__enter__()

    def tearDown(self):
        self.capture.__exit__(None, None, None)
        self.shared.stop()
        self.tmp.cleanup()

    def run_flow(self, fake, **kwargs):
        return lc.workflow(args(**kwargs), fake, self.path)

    def test_wait_at_first_no_mutation(self):
        fake = Fake()
        self.assertEqual(self.run_flow(fake), 2)
        self.assertEqual(fake.calls, ['access'])
        self.assertFalse(fake.executions)

    def test_skip_requires_live_check_on_every_resume(self):
        fake = Fake(['access', 'infra'])
        self.assertEqual(self.run_flow(fake), 2)
        fake.complete.remove('access')
        fake.calls.clear()
        self.assertEqual(self.run_flow(fake), 2)
        self.assertEqual(fake.calls, ['access'])

    def test_cannot_jump_forward_with_execute(self):
        fake = Fake(['access'])
        self.assertEqual(self.run_flow(fake, execute='content'), 2)
        self.assertFalse(fake.executions)
        self.assertEqual(fake.calls, ['access', 'infra'])

    def test_exactly_one_authorized_step(self):
        fake = Fake(['access', 'infra', 'data', 'context'])
        self.assertEqual(self.run_flow(fake, execute='argocd'), 2)
        self.assertEqual(fake.executions, ['argocd'])
        self.assertEqual(fake.calls[-1], 'controllers')

    def test_failure_saved_without_output_then_resume(self):
        fake = Fake(['access', 'infra'], fail='data')
        with self.assertRaises(SafeError):
            self.run_flow(fake)
        raw = self.path.read_text()
        self.assertNotIn('123456789012', raw)
        self.assertNotIn('203.0.113.8', raw)
        self.assertNotIn('TOKEN', raw)
        self.assertEqual(json.loads(raw)['steps']['data']['result'], 'failed')
        fake.fail = None
        fake.complete.add('data')
        self.assertEqual(self.run_flow(fake), 2)
        self.assertEqual(len(json.loads(self.path.read_text())['steps']['data']['attempts']), 2)

    def test_full_up(self):
        self.assertEqual(self.run_flow(Fake(s.key for s in lc.UP)), 0)
        self.assertIn('finished', json.loads(self.path.read_text()))
        self.assertIn('전체 경과:', self.output.getvalue())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)

    def test_explicit_verify_invalidates_old_receipt_and_runs_again(self):
        fake = Fake(s.key for s in lc.UP)
        self.run_flow(fake)
        state = json.loads(self.path.read_text())
        state['receipts']['content'] = 'old-receipt'
        self.path.write_text(json.dumps(state))
        a = args(execute='content')
        a.verify_existing = True
        self.assertEqual(lc.workflow(a, fake, self.path), 0)
        self.assertEqual(fake.executions, ['content'])
        self.assertNotIn('content', json.loads(self.path.read_text())['receipts'])

    def test_changed_generation_blocks_completed_run(self):
        fake = Fake(s.key for s in lc.UP)
        self.run_flow(fake)
        fake.binding_value = 'b' * 64
        with self.assertRaises(SafeError):
            self.run_flow(fake)

    def test_wrong_account_blocks_even_before_infra(self):
        fake = Fake()
        self.run_flow(fake)
        a = args()
        a.expected_account_id = '000000000000'
        with self.assertRaises(SafeError):
            lc.workflow(a, fake, self.path)


    def test_down_mismatched_state_stops_before_first_step(self):
        fake = Fake(s.key for s in lc.DOWN)
        fake.destination = Mock(side_effect=SafeError('state mismatch'))
        with self.assertRaises(SafeError):
            self.run_flow(fake, direction='down', execute='destroy')
        self.assertEqual(fake.calls, [])
        self.assertEqual(fake.executions, [])

    def test_down_order_alb_before_data_or_destroy(self):
        fake = Fake(['access', 'context', 'ingress-removed'])
        self.assertEqual(self.run_flow(fake, direction='down', execute='destroy'), 2)
        self.assertEqual(fake.calls[-1], 'alb-gone')
        self.assertFalse(fake.executions)
        self.assertNotIn('data-removed', fake.calls)

    def test_down_requires_actual_ingress_removal(self):
        fake = Fake(['access', 'context'])
        self.run_flow(fake, direction='down')
        self.assertEqual(fake.calls[-1], 'ingress-removed')

    def test_shutdown_preparation_stops_at_data_review(self):
        fake = Fake(['access', 'context'])
        options = args(direction='down')
        options.prepare_down = True
        self.assertEqual(lc.workflow(options, fake, self.path), 2)
        self.assertEqual(fake.executions, ['ingress-removed', 'alb-gone', 'apps-removed', 'data-removed'])
        self.assertNotIn('destroy', fake.calls)
        self.assertEqual(json.loads(self.path.read_text())['steps']['data-removed']['result'], 'waiting')

    def test_shutdown_preparation_cannot_bypass_preflight(self):
        fake = Fake(['access'])
        options = args(direction='down')
        options.prepare_down = True
        self.assertEqual(lc.workflow(options, fake, self.path), 2)
        self.assertEqual(fake.executions, [])

    def test_down_absence_not_assumed_clean(self):
        fake = Fake()
        fake.present = False
        with self.assertRaises(SafeError):
            self.run_flow(fake, direction='down')

    def test_resume_after_destroy_does_not_call_dead_context(self):
        fake = Fake(s.key for s in lc.DOWN)
        self.assertEqual(self.run_flow(fake, direction='down'), 0)
        fake.present = False
        fake.binding_value = 'b' * 64
        fake.calls.clear()
        self.assertEqual(self.run_flow(fake, direction='down'), 0)
        self.assertEqual(fake.calls, ['destroy', 'residue'])

    def test_lock_rejects_concurrent_run(self):
        with lc.locked_state(self.path):
            with self.assertRaises(SafeError):
                self.run_flow(Fake())

    def test_symlink_state_rejected(self):
        self.path.parent.mkdir()
        self.path.symlink_to(Path(self.tmp.name) / 'elsewhere')
        with self.assertRaises(SafeError):
            self.run_flow(Fake())



class ShutdownPreparation(unittest.TestCase):
    def setUp(self):
        self.live = object.__new__(lc.Live)
        self.live.args = args(direction='down')

    def app(self, name):
        namespace, path = lc.SHUTDOWN_APPS[name]
        return {
            'metadata': {'name': name, 'uid': 'uid', 'resourceVersion': '2'},
            'spec': {'destination': {'server': 'https://kubernetes.default.svc', 'namespace': namespace},
                     'source': {'repoURL': lc.GITOPS_REPO, 'path': path, 'targetRevision': 'main'}},
        }

    def test_root_and_namespace_are_deleted_without_argocd_cascade(self):
        for name in (lc.ROOT_APP, 'ureka-eks-namespace-dev'):
            self.live.app = Mock(return_value=self.app(name))
            self.live.run = Mock()
            self.live.delete_shutdown_app(name)
            self.live.run.assert_called_once()
            cmd, body = self.live.run.call_args.args
            self.assertIn('--raw', cmd)
            self.assertEqual(json.loads(body)['propagationPolicy'], 'Orphan')
            self.assertEqual(json.loads(body)['preconditions'], {'uid': 'uid', 'resourceVersion': '2'})

    def test_ingress_cascades_only_after_finalizer_patch(self):
        current = self.app(lc.INGRESS_APP)
        self.live.app = Mock(return_value=current)
        updated = self.app(lc.INGRESS_APP)
        updated['metadata'].update(finalizers=[lc.APP_FINALIZER], resourceVersion='3')
        self.live.run = Mock(side_effect=[json.dumps(updated), ''])
        self.live.delete_shutdown_app(lc.INGRESS_APP)
        patch, delete = [call.args for call in self.live.run.call_args_list]
        self.assertIn('patch', patch[0])
        self.assertEqual(json.loads(patch[1])[1]['value'], [lc.APP_FINALIZER])
        self.assertEqual(json.loads(delete[1])['preconditions']['resourceVersion'], '3')

    def test_chat_accepts_both_expected_releases(self):
        name = 'ureka-chat-eks-dev'
        app = self.app(name)
        source = app['spec'].pop('source')
        app['spec']['sources'] = [dict(source, helm={'releaseName': release})
                                  for release in ('chat', 'chat-worker')]
        self.live.check_shutdown_app(name, app)
        app['spec']['sources'].append(dict(source, helm={'releaseName': 'auth'}))
        with self.assertRaises(SafeError):
            self.live.check_shutdown_app(name, app)

    def test_unknown_apps_and_pvcs_stop_inventory(self):
        for inventory in (
            {'applications': [{'metadata': {'name': 'unknown'}}]},
            {'pvc': [{'metadata': {'name': 'retained'}}]},
        ):
            self.live.items = lambda kind, ns: inventory.get(kind, [])
            with self.assertRaises(SafeError):
                self.live.shutdown_inventory()

    def test_apps_cleanup_stops_if_load_balancer_returns(self):
        self.live.destination = Mock()
        self.live.shutdown_inventory = Mock()
        self.live.albs = Mock(return_value=[{'name': 'still-running'}])
        self.live.delete_shutdown_app = Mock()
        with self.assertRaises(lc.ShutdownPreparationError):
            self.live.prepare_down_step('apps-removed', {})
        self.live.delete_shutdown_app.assert_not_called()


class DataDetachPlan(unittest.TestCase):
    def setUp(self):
        old_rule = {'protocol': 'tcp', 'from_port': 5432, 'to_port': 5432,
                    'security_groups': ['sg-node'], 'cidr_blocks': [], 'self': False}
        self.ec2_rule = dict(old_rule, security_groups=['sg-ec2'])
        self.change = {'actions': ['update'],
                       'before': {'id': 'sg-rds', 'ingress': [old_rule, self.ec2_rule], 'egress': []},
                       'after': {'id': 'sg-rds', 'ingress': [self.ec2_rule], 'egress': []},
                       'after_unknown': {'ingress': [{'security_groups': [False]}]}}
        self.plan = {'applyable': True, 'complete': True, 'resource_changes': [
            {'mode': 'managed', 'address': 'aws_security_group.rds', 'change': self.change}]}

    def test_only_the_eks_ingress_rule_may_be_removed(self):
        lc.check_data_detach_plan(self.plan, 'sg-rds', 'sg-node')
        self.change['after']['ingress'] = []
        with self.assertRaises(SafeError):
            lc.check_data_detach_plan(self.plan, 'sg-rds', 'sg-node')

    def test_unknown_after_value_is_rejected(self):
        self.change['after_unknown']['ingress'][0]['security_groups'] = [True]
        with self.assertRaises(SafeError):
            lc.check_data_detach_plan(self.plan, 'sg-rds', 'sg-node')

    def test_database_change_is_rejected(self):
        self.plan['resource_changes'].append(
            {'mode': 'managed', 'address': 'aws_db_instance.unexpected', 'change': {'actions': ['delete']}})
        with self.assertRaises(SafeError):
            lc.check_data_detach_plan(self.plan, 'sg-rds', 'sg-node')

    def test_only_validated_plan_is_published_without_applying_or_editing_tfvars(self):
        live = object.__new__(lc.Live)
        live.outputs = lambda stack='eks': ({'node_security_group_id': 'sg-node'} if stack == 'eks'
                                            else {'security_group_id': 'sg-rds'})
        live.data_vars = lambda: {'nodes': ['sg-node']}
        def terraform(command):
            if command[2] == 'workspace':
                return 'default'
            if command[2] == 'plan':
                self.assertIn('-var=eks_node_security_group_ids=[]', command)
                Path(command[-1].split('=', 1)[1]).write_bytes(b'synthetic plan')
                return 'local plan output'
            self.assertEqual(command[2], 'show')
            return json.dumps(self.plan)
        live.run = terraform
        with tempfile.TemporaryDirectory() as workdir:
            root = Path(workdir)
            artifacts = root / '.local/eks'
            artifacts.mkdir(parents=True)
            with patch.object(lc, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                live.plan_data_detach()
                self.assertEqual(len(list(artifacts.glob('*/saved.tfplan'))), 1)
                self.change['after']['ingress'] = []
                with self.assertRaises(lc.ShutdownPreparationError):
                    live.plan_data_detach()
            self.assertEqual(len(list(artifacts.glob('*/saved.tfplan'))), 1)
            self.assertEqual(len(list(artifacts.glob('*/plan.log'))), 2)
            self.assertFalse(list(artifacts.glob('*/unverified.tfplan')))


class DNSResumeFake(Fake):
    """Real public-infra guard/state recording, mocked external reads and other checkpoints."""
    def __init__(self):
        super().__init__(s.key for s in lc.UP)
        self.dns_enabled = False
        self.dns_ready = False
        self.targets_healthy = True
        self.public_failure = False
        self.public_reads = 0
        self.public = object.__new__(lc.Live)
        self.public.binding = lambda: self.binding_value
        self.public.tfvars = lambda: {'mode': 'testers', 'public': True, 'dns': self.dns_enabled,
                                     'testers': ['synthetic-entry']}
        self.public.aws = self.read_public

    def read_public(self, service, action, *args, **kwargs):
        self.public_reads += 1
        if self.public_failure:
            raise SafeError('temporary public read failure')
        if action == 'list-roles':
            return {'Roles': [{'RoleName': 'ureka-eks-aws-load-balancer-controller'}]}
        if action == 'list-web-acls':
            return {'WebACLs': [{'Name': 'ureka-eks-public'}]}
        if action == 'describe-security-groups':
            return {'SecurityGroups': [{'IpPermissions': [
                {'IpProtocol': 'tcp', 'FromPort': port, 'ToPort': port,
                 'PrefixListIds': [{'PrefixListId': 'synthetic-list'}]} for port in (80, 443)]}]}
        if action == 'get-managed-prefix-list-entries':
            return {'Entries': [{'Cidr': 'synthetic-entry'}]}
        raise AssertionError('unexpected public read')

    def check(self, key, state):
        self.calls.append(key)
        if key == 'public-infra':
            return lc.Live.check(self.public, key, state)
        if key == 'targets':
            return self.targets_healthy
        if key == 'dns':
            return self.dns_enabled and self.dns_ready
        return key in self.complete

    def execute(self, step, state):
        self.executions.append(step.key)
        if step.key != 'dns':
            raise AssertionError('unexpected execution')
        self.dns_ready = True


class DNSResumeWorkflow(unittest.TestCase):
    setUp = Workflow.setUp
    tearDown = Workflow.tearDown
    run_flow = Workflow.run_flow

    def prepared(self):
        fake = DNSResumeFake()
        self.assertEqual(self.run_flow(fake), 2)
        self.assertEqual(fake.calls[-1], 'dns')
        fake.dns_enabled = True
        fake.calls.clear()
        fake.public_reads = 0
        return fake

    def test_same_run_recovers_after_target_waiting(self):
        fake = self.prepared()
        fake.targets_healthy = False
        self.assertEqual(self.run_flow(fake, execute='dns'), 2)
        self.assertEqual(fake.calls[-1], 'targets')
        self.assertFalse(fake.executions)
        fake.targets_healthy = True
        fake.calls.clear()
        self.assertEqual(self.run_flow(fake, execute='dns'), 0)
        self.assertGreater(fake.public_reads, 0)
        self.assertIn('alb-policy', fake.calls)
        self.assertIn('targets', fake.calls)
        self.assertEqual(fake.executions, ['dns'])

    def test_same_run_recovers_after_public_read_failure(self):
        fake = self.prepared()
        fake.public_failure = True
        with self.assertRaises(SafeError):
            self.run_flow(fake, execute='dns')
        self.assertEqual(json.loads(self.path.read_text())['steps']['public-infra']['result'], 'failed')
        self.assertFalse(fake.executions)
        fake.public_failure = False
        before = fake.public_reads
        fake.calls.clear()
        self.assertEqual(self.run_flow(fake, execute='dns'), 0)
        self.assertGreater(fake.public_reads, before)
        self.assertIn('alb-policy', fake.calls)
        self.assertIn('targets', fake.calls)
        self.assertEqual(fake.executions, ['dns'])

    def test_without_eligibility_history_dns_true_is_rejected(self):
        fake = DNSResumeFake()
        fake.dns_enabled = True
        with self.assertRaises(SafeError):
            self.run_flow(fake, execute='dns')
        self.assertEqual(fake.public_reads, 0)
        self.assertFalse(fake.executions)

    def test_other_cluster_attempts_do_not_grant_eligibility(self):
        fake = self.prepared()
        state = json.loads(self.path.read_text())
        for key in ('public-infra', 'alb-policy', 'targets'):
            for attempt in state['steps'][key]['attempts']:
                attempt['binding'] = 'b' * 64
        self.path.write_text(json.dumps(state))
        with self.assertRaises(SafeError):
            self.run_flow(fake, execute='dns')
        self.assertEqual(fake.public_reads, 0)
        self.assertFalse(fake.executions)

    def test_still_unhealthy_targets_never_execute_dns(self):
        fake = self.prepared()
        fake.targets_healthy = False
        for _ in range(2):
            fake.calls.clear()
            before = fake.public_reads
            self.assertEqual(self.run_flow(fake, execute='dns'), 2)
            self.assertGreater(fake.public_reads, before)
            self.assertIn('alb-policy', fake.calls)
            self.assertEqual(fake.calls[-1], 'targets')
            self.assertFalse(fake.executions)


class PlanAndCli(unittest.TestCase):
    def test_plan_only_has_zero_external_calls_or_state_writes(self):
        with patch.object(lc, 'Live', side_effect=AssertionError('must not initialize')), patch.object(lc, 'save', side_effect=AssertionError('must not write')):
            for direction in ('up', 'down'):
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(lc.main([direction, '--plan-only']), 0)
                self.assertIn('외부 호출·파일 생성 없음', out.getvalue())
                self.assertIn('확인', out.getvalue())

    def test_actual_existing_cli_help_without_network(self):
        # Actual CPython subprocess + all existing CLI parsers, not fake shell commands.
        # Does NOT substitute for a future authorized AWS API smoke.
        for tool in ('operate.py', 'bootstrap_argocd.py', 'register_root_app.py', 'register_secrets_app.py',
                     'register_lbc_app.py', 'seed_prod_secrets.py', 'bootstrap_prod_db.py', 'copy_prod_content.py'):
            r = subprocess.run([sys.executable, str(ROOT / 'scripts/eks' / tool), '--help'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, tool)

    def test_real_kubectl_local_patch_file_stdin_support(self):
        # Offline kubectl flag parser only. No kubeconfig/server read or API request.
        import shutil
        if not shutil.which('kubectl'):
            self.skipTest('kubectl not installed')
        r = subprocess.run(['kubectl', 'patch', '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn('--patch-file', r.stdout)

    def test_real_terraform_console_sensitive_json_without_provider(self):
        import shutil
        if not shutil.which('terraform'):
            self.skipTest('terraform not installed')
        # Real CLI, local-only fixture: no backend/provider/credential/API use.
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'main.tf').write_text('variable "cidrs" {\n type = list(string)\n sensitive = true\n default = ["203.0.113.1/32"]\n}\n')
            r = subprocess.run(['terraform', '-chdir=' + folder, 'console'],
                input='nonsensitive(jsonencode({ip=var.cidrs}))\n', capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, 'local Terraform console failed (raw output suppressed)')
            self.assertEqual(json.loads(json.loads(r.stdout.strip())), {'ip': ['203.0.113.1/32']})

    @unittest.skipUnless(os.environ.get('UREKA_RUN_AWS_READONLY_SMOKE') == '1', 'AWS/cluster calls not authorized in implementation task')
    def test_real_aws_readonly_identity(self):
        # Operator opt-in only, no raw stdout/stderr exposed; no resource changes.
        a = args()
        a.profile = os.environ.get('UREKA_OPS_PROFILE', '')
        a.expected_account_id = os.environ.get('UREKA_EXPECTED_ACCOUNT_ID', '')
        self.assertTrue(a.profile and a.expected_account_id, 'approved profile/account input required')
        live = lc.Live(a)
        live.identity()


class PatchSafety(unittest.TestCase):
    def test_first_patch_is_atomic_and_preserves_registry(self):
        existing = [{'name': 'ecrRegistry', 'value': 'PRIVATE'}]
        patch = lc.cidr_patch(existing, ['10.1.0.0/24', '10.0.0.0/24'])
        self.assertEqual(patch[0], {'op': 'test', 'path': '/spec/source/helm/parameters', 'value': existing})
        self.assertEqual(len(patch), 4)
        self.assertTrue(all(p['path'].endswith('/-') for p in patch[1:]))

    def test_identical_is_noop(self):
        additions = lc.cidr_patch([], ['10.0.0.0/24'])
        self.assertEqual(lc.cidr_patch([x['value'] for x in additions[1:]], ['10.0.0.0/24']), [])

    def test_duplicate_or_drift_is_error(self):
        good = [x['value'] for x in lc.cidr_patch([], ['10.0.0.0/24'])[1:]]
        for bad in (good + [good[0]], good[:-1], [{'name': 'networkPolicy.alb.enabled', 'value': 'false'}]):
            with self.assertRaises(SafeError):
                lc.cidr_patch(bad, ['10.0.0.0/24'])

    def test_public_or_invalid_cidrs_rejected(self):
        for bad in ([], ['8.8.8.0/24'], ['10.0.0.0/24'] * 2):
            with self.assertRaises(ValueError):
                lc.cidr_patch([], bad)


class LiveSafety(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.live = lc.Live(args())

    def tearDown(self):
        self.env.stop()

    def test_unknown_or_manual_step_cannot_execute(self):
        with patch.object(self.live, 'destination'):
            with self.assertRaises(SafeError):
                self.live.execute(lc.UP[2], {})

    def test_missing_confirmation_does_not_invoke_child(self):
        with patch.object(self.live, 'run') as run:
            with self.assertRaises(SafeError):
                self.live.child(('bootstrap_prod_db.py', 'apply'), confirm=True)
            run.assert_not_called()

    def test_confirmation_forwarded_to_existing_cli(self):
        self.live.args.confirm_env = 'prod'
        with patch.object(self.live, 'run') as run:
            self.live.child(('bootstrap_prod_db.py', 'apply'), confirm=True)
            command = run.call_args.args[0]
            self.assertEqual(command[-2:], ['--confirm-env', 'prod'])
            self.assertNotIn('123456789012', command)

    def test_wrong_context_blocks_before_mutation(self):
        with patch.object(self.live, 'destination', side_effect=SafeError('wrong')), patch.object(self.live, 'child') as child:
            with self.assertRaises(SafeError):
                self.live.execute(next(s for s in lc.UP if s.key == 'argocd'), {})
            child.assert_not_called()

    def test_subprocess_failure_does_not_log_or_print_raw(self):
        result = Mock(returncode=1, stdout='TOKEN 123456789012', stderr='203.0.113.8')
        with patch.object(subprocess, 'run', return_value=result), patch.object(Path, 'write_text') as write:
            with self.assertRaises(SafeError) as error:
                self.live.run(['fake'])
            write.assert_not_called()
            self.assertNotIn('TOKEN', str(error.exception))

    def test_notfound_is_absence_but_forbidden_is_error(self):
        with patch.object(self.live, 'run', return_value=''):
            self.assertIsNone(self.live.get('application', 'x'))
        with patch.object(self.live, 'run', side_effect=SafeError('RBAC')):
            with self.assertRaises(SafeError):
                self.live.get('application', 'x')

    def test_db_metadata_check_never_counts_as_completed_copy(self):
        with patch.object(self.live, 'receipt_target', return_value='target'):
            self.assertFalse(self.live.check('content', {}))
            self.assertTrue(self.live.check('content', {'receipts': {'content': 'target'}}))
            self.assertFalse(self.live.check('content', {'receipts': {'content': 'old-target'}}))

    def test_secrets_are_not_read_for_initial_admin_presence(self):
        with patch.object(self.live, 'run', return_value='secret/x') as run:
            self.assertTrue(self.live.get('secret', 'x', 'argocd'))
            self.assertEqual(run.call_args.args[0][-2:], ['-o', 'name'])

    def test_existing_content_uses_verify_not_apply(self):
        self.live.args.verify_existing = True
        self.live.args.confirm_env = 'prod'
        state = {}
        with patch.object(self.live, 'destination'), patch.object(self.live, 'receipt_target', return_value='target'), patch.object(self.live, 'child') as child:
            self.live.execute(next(s for s in lc.UP if s.key == 'content'), state)
            child.assert_called_once_with(('copy_prod_content.py', 'verify'), confirm=True)
        self.assertEqual(state['receipts']['content'], 'target')

    def test_registered_root_is_not_reapplied_while_waiting_for_health(self):
        with patch.object(self.live, 'destination'), patch.object(self.live, 'app', return_value={'spec': {}}), patch.object(self.live, 'child') as child:
            self.live.execute(next(s for s in lc.UP if s.key == 'root'), {})
            child.assert_not_called()

    def test_dev_copy_flag_requires_actual_permission_removal(self):
        with patch.object(self.live, 'data_vars', return_value={'copy': False, 'role': 'fake'}), patch.object(self.live, 'secret_metadata', return_value={'Name': 'present'}), patch.object(self.live, 'aws', return_value={'PolicyNames': ['eks-dev-secret-copy']}):
            self.assertFalse(self.live.check('dev-secrets', {}))
        with patch.object(self.live, 'data_vars', return_value={'copy': False, 'role': 'fake'}), patch.object(self.live, 'secret_metadata', return_value={'Name': 'present'}), patch.object(self.live, 'aws', return_value={'PolicyNames': []}):
            self.assertTrue(self.live.check('dev-secrets', {}))

    def test_alb_patch_requires_cluster_confirmation(self):
        with patch.object(self.live, 'destination'), patch.object(self.live, 'run') as run:
            with self.assertRaises(SafeError):
                self.live.execute(next(s for s in lc.UP if s.key == 'alb-policy'), {})
            run.assert_not_called()

    def test_destroy_cannot_apply_create_plan(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as folder:
            root = Path(folder)
            review = root / '.local/eks/review-example'
            review.mkdir(parents=True)
            (review / 'review.json').write_text(json.dumps({'destroy': False}))
            self.live.args.review_dir = str(review)
            self.live.args.confirm = 'hash'
            with patch.object(lc, 'ROOT', root), patch.object(lc.Live, 'apply') as apply:
                with self.assertRaises(SafeError):
                    self.live.execute(next(s for s in lc.DOWN if s.key == 'destroy'), {})
                apply.assert_not_called()

    def test_unknown_connection_limit_stops_without_query(self):
        with patch.object(self.live, 'aws') as aws:
            with self.assertRaises(SafeError):
                self.live.check('connections', {})
            aws.assert_not_called()



class TargetAndPhaseSafety(unittest.TestCase):
    def plan(self, phase, address, actions=None):
        flags = {'infra': (False, False), 'public-infra': (True, False), 'dns': (True, True), 'destroy': (True, True)}
        public, dns = flags[phase]
        return {'variables': {k: {'value': v} for k, v in {
            'aws_region': lc.REGION, 'project_name': 'ureka', 'public_access_mode': 'testers',
            'public_enabled': public, 'public_dns_enabled': dns}.items()},
            'resource_changes': [{'mode': 'managed', 'address': address, 'type': address.split('.')[0],
                                  'change': {'actions': actions or ['create']}}]}

    def test_allowlisted_phase_changes(self):
        for phase, address in [('infra', 'aws_eks_cluster.this'),
                               ('public-infra', 'aws_wafv2_web_acl.public[0]'),
                               ('public-infra', 'aws_route53_record.cert_validation["example.invalid"]'),
                               ('dns', 'aws_route53_record.public["example.invalid"]'),
                               ('destroy', 'aws_vpc_security_group_ingress_rule.alb_open["https"]')]:
            with self.subTest(phase=phase):
                lc.check_plan_scope(self.plan(phase, address, ['delete'] if phase == 'destroy' else None), phase, 'ureka-eks')

    def test_other_phase_or_foreign_stack_resource_is_rejected(self):
        for phase, address in [('infra', 'aws_wafv2_web_acl.public[0]'),
                               ('infra', 'aws_route53_record.public["example.invalid"]'),
                               ('public-infra', 'aws_eks_cluster.this'),
                               ('public-infra', 'aws_route53_record.public["example.invalid"]'),
                               ('dns', 'aws_wafv2_web_acl.public[0]'),
                               ('dns', 'aws_route53_record.cert_validation["example.invalid"]'),
                               ('destroy', 'aws_db_instance.this'),
                               ('destroy', 'module.network.aws_vpc.this')]:
            with self.subTest(phase=phase, address=address), self.assertRaises(SafeError):
                lc.check_plan_scope(self.plan(phase, address, ['delete'] if phase == 'destroy' else None), phase, 'ureka-eks')

    def test_open_early_dns_and_replacements_are_rejected(self):
        for phase in ('infra', 'public-infra', 'dns'):
            plan = self.plan(phase, 'aws_eks_cluster.this')
            plan['variables']['public_access_mode']['value'] = 'open'
            with self.subTest(phase=phase), self.assertRaises(SafeError):
                lc.check_plan_scope(plan, phase, 'ureka-eks')
        for phase in ('infra', 'public-infra'):
            plan = self.plan(phase, 'aws_eks_cluster.this')
            plan['variables']['public_dns_enabled']['value'] = True
            with self.assertRaises(SafeError):
                lc.check_plan_scope(plan, phase, 'ureka-eks')
        with self.assertRaises(SafeError):
            lc.check_plan_scope(self.plan('infra', 'aws_eks_cluster.this', ['delete', 'create']), 'infra', 'ureka-eks')

    def test_wrong_plan_region_or_cluster_is_rejected(self):
        plan = self.plan('infra', 'aws_eks_cluster.this')
        plan['variables']['aws_region']['value'] = 'other-region'
        with self.assertRaises(SafeError):
            lc.check_plan_scope(plan, 'infra', 'ureka-eks')
        plan['variables']['aws_region']['value'] = lc.REGION
        with self.assertRaises(SafeError):
            lc.check_plan_scope(plan, 'infra', 'another-eks')

    def test_saved_plan_phase_and_actual_changes_checked_before_apply(self):
        for phase, original, address in [('public-infra', 'dns', 'aws_route53_record.public[0]'),
                                         ('dns', 'public-infra', 'aws_wafv2_web_acl.public[0]'),
                                         ('dns', 'dns', 'aws_wafv2_web_acl.public[0]')]:
            with self.subTest(phase=phase, original=original), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                review = root / '.local/eks/review-test'
                review.mkdir(parents=True)
                (review / 'review.json').write_text(json.dumps({'destroy': False, 'lifecycle_step': original}))
                a = args(execute=phase)
                a.review_dir, a.confirm = str(review), 'synthetic-hash'
                live = object.__new__(lc.Live)
                live.args = a
                operator = Mock()
                operator.tf.return_value = json.dumps(self.plan(phase, address))
                with patch.object(lc, 'ROOT', root), patch.object(lc, 'Live', return_value=operator):
                    with self.assertRaises(SafeError):
                        live.execute(next(step for step in lc.UP if step.key == phase), {})
                operator.apply.assert_not_called()

    def test_destination_checks_state_name_endpoint_node_sg_and_region(self):
        live = object.__new__(lc.Live)
        live.args = args(direction='down')
        c = {'name': live.args.cluster_name, 'arn': ':'.join(('arn', 'aws', 'eks', lc.REGION,
             live.args.expected_account_id, 'cluster/' + live.args.cluster_name)), 'endpoint': 'https://cluster.invalid',
             'status': 'ACTIVE', 'resourcesVpcConfig': {'vpcId': 'vpc-synthetic', 'securityGroupIds': []}}
        config = {'current-context': live.args.context, 'contexts': [{'context': {'cluster': 'target'}}],
                  'clusters': [{'name': 'target', 'cluster': {'server': c['endpoint']}}]}
        good = {'cluster_name': c['name'], 'cluster_endpoint': c['endpoint'], 'node_security_group_id': 'sg-synthetic'}
        group = {'GroupId': 'sg-synthetic', 'OwnerId': live.args.expected_account_id,
                 'VpcId': 'vpc-synthetic', 'GroupName': live.args.cluster_name + '-nodes',
                 'Tags': [{'Key': k, 'Value': v} for k, v in {'Project': 'ureka', 'Stack': 'eks', 'ManagedBy': 'terraform'}.items()]}
        with patch.object(live, 'cluster', return_value=c), patch.object(live, 'run', return_value=json.dumps(config)), patch.object(live, 'outputs', return_value=good), patch.object(live, 'aws', return_value={'SecurityGroups': [group]}):
            self.assertEqual(live.destination(), c)
            for key, value in [('cluster_name', 'other-eks'), ('cluster_endpoint', 'https://other.invalid'),
                               ('node_security_group_id', 'sg-other')]:
                with self.subTest(key=key), patch.object(live, 'outputs', return_value={**good, key: value}):
                    with self.assertRaises(SafeError):
                        live.destination()
            for key, value in [('OwnerId', 'other-account'), ('VpcId', 'vpc-other'), ('GroupName', 'other-nodes'), ('Tags', [])]:
                with self.subTest(group_key=key), patch.object(live, 'aws', return_value={'SecurityGroups': [{**group, key: value}]}):
                    with self.assertRaises(SafeError):
                        live.destination()
            wrong = dict(c, arn=c['arn'].replace(lc.REGION, 'other-region'))
            with patch.object(live, 'cluster', return_value=wrong), self.assertRaises(SafeError):
                live.destination()

    def test_fresh_public_infra_rejects_enabled_dns(self):
        live = object.__new__(lc.Live)
        with patch.object(live, 'tfvars', return_value={'mode': 'testers', 'public': True, 'dns': True}), patch.object(live, 'aws') as aws:
            with self.assertRaises(SafeError):
                live.check('public-infra', {})
            aws.assert_not_called()

    def test_valid_plan_keeps_existing_apply_delegation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            review = root / '.local/eks/review-test'
            review.mkdir(parents=True)
            (review / 'review.json').write_text(json.dumps({'destroy': False, 'lifecycle_step': 'dns'}))
            a = args(execute='dns')
            a.review_dir, a.confirm = str(review), 'synthetic-hash'
            live = object.__new__(lc.Live)
            live.args = a
            operator = Mock()
            operator.tf.return_value = json.dumps(self.plan('dns', 'aws_route53_record.public[0]'))
            with patch.object(lc, 'ROOT', root), patch.object(lc, 'Live', return_value=operator), patch.object(live, 'check', return_value=True) as check:
                live.execute(next(step for step in lc.UP if step.key == 'dns'), {})
            check.assert_called_once_with('targets', {})
            operator.apply.assert_called_once_with()

    def test_plan_creation_adds_phase_to_hashed_review(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            review = root / '.local/eks/review-test'
            review.mkdir(parents=True)
            (review / 'review.json').write_text(json.dumps({'destroy': False, 'plan_sha256': 'synthetic-digest'}))
            live = object.__new__(lc.Live)
            live.args = args(execute='infra')
            operator = Mock()
            operator.plan.side_effect = lambda **kwargs: print('plan 저장 위치: .local/eks/review-test')
            operator.tf.return_value = json.dumps(self.plan('infra', 'aws_eks_cluster.this'))
            with patch.object(lc, 'ROOT', root), patch.object(lc, 'Live', return_value=operator), patch.object(live, 'tfvars', return_value={'mode': 'testers', 'public': False, 'dns': False}), contextlib.redirect_stdout(io.StringIO()) as output:
                live.execute(next(step for step in lc.UP if step.key == 'infra'), {})
            saved = json.loads((review / 'review.json').read_text())
            self.assertEqual(saved['lifecycle_step'], 'infra')
            self.assertIn(lc.fingerprint(saved), output.getvalue())
            self.assertEqual(saved['plan_sha256'], 'synthetic-digest')
            operator.apply.assert_not_called()

    def test_allowlist_matches_only_current_eks_managed_addresses(self):
        import re
        addresses = set()
        for path in (ROOT / 'infra/environments/eks').glob('*.tf'):
            addresses.update(kind + '.' + name for kind, name in re.findall(r'^resource "([^"]+)" "([^"]+)"', path.read_text(), re.M))
        self.assertEqual(addresses, lc.DESTROY_RESOURCES)

    def test_destroy_cleanup_revalidates_destination_after_init(self):
        live = object.__new__(lc.Live)
        with patch.object(live, 'destination', side_effect=SafeError('mismatch')), patch.object(lc.Operator, 'cleanup_gate') as cleanup:
            with self.assertRaises(SafeError):
                live.cleanup_gate()
            cleanup.assert_not_called()

    def test_common_git_directory_resolves_from_two_worktrees(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            common = root / 'repo/.git'
            for name in ('a', 'b'):
                worktree = root / name
                worktree.mkdir()
                admin = common / 'worktrees' / name
                admin.mkdir(parents=True)
                (admin / 'commondir').write_text('../..')
                (worktree / '.git').write_text('gitdir: ' + str(admin))
                with patch.object(lc, 'ROOT', worktree):
                    self.assertEqual(lc.shared_lock_root(), common.resolve() / 'ureka-lifecycle-locks')

    def test_two_worktrees_and_directions_share_target_lock(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.object(lc, 'shared_lock_root', return_value=root / 'shared'):
                with lc.locked_state(root / 'a/up/state.json'), lc.locked_target(args('up')):
                    with lc.locked_state(root / 'b/down/state.json'):
                        with self.assertRaises(SafeError):
                            with lc.locked_target(args('down')):
                                self.fail('same target acquired twice')
                    other = args('down')
                    other.cluster_name = 'other-eks'
                    with lc.locked_target(other):
                        pass
                # File remains, but closing the descriptor releases the advisory lock.
                with lc.locked_target(args('down')):
                    pass
                for path in (root / 'shared').iterdir():
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertRegex(path.name, r'^[0-9a-f]{64}\.lock$')
                self.assertEqual((root / 'shared').stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
