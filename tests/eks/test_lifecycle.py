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
        confirm_cleanup=None, confirm_residue=None)


class Fake:
    def __init__(self, complete=(), fail=None):
        self.complete, self.fail = set(complete), fail
        self.calls, self.executions = [], []
        self.binding_value = 'a' * 64
        self.present = True

    def identity(self):
        pass

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


class Workflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'up-20261124/state.json'
        self.output = io.StringIO()
        self.capture = contextlib.redirect_stdout(self.output)
        self.capture.__enter__()

    def tearDown(self):
        self.capture.__exit__(None, None, None)
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


if __name__ == '__main__':
    unittest.main()
