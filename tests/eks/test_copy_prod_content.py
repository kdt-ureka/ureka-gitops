"""Operator lifecycle: fake AWS/cluster only; SQL safety cases are also exercised in local Docker."""
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'scripts/eks'))
sys.path.insert(0, str(HERE))
import test_bootstrap_prod_db as b
import copy_prod_content as m


class Cluster(b.FakeCluster):
    def handle(self, command, stdin):
        if command[0] == 'kubectl':
            verb, rest = command[6], command[7:]
            if verb == 'create' and stdin and 'kind: Job' in stdin:
                key = 'job/' + m.JOB
                if self.fail_create == key:
                    return 1, '', 'Error from server (Forbidden)'
                if key in self.objects:
                    return 1, '', 'Error from server (AlreadyExists)'
                self.objects[key] = b.RUN_RE.search(stdin)[1]
                self.bodies[key] = stdin
                self.created.append(key)
                return 0, '', ''
            if verb == 'get' and rest[:2] == ['job', m.JOB] and 'job/' + m.JOB in self.objects:
                if self.job_result == 'interrupt':
                    self.job_result = 'label-only'
                    raise KeyboardInterrupt
                status = {'ok': {'succeeded': 1}, 'failed': {'failed': 1}, 'timeout': {}, 'label-only': {}}[self.job_result]
                return 0, json.dumps({'status': status, 'metadata': {'labels': {
                    m.RUN_LABEL: self.objects['job/' + m.JOB]}}}), ''
            if verb == 'logs':
                return 0, 'copy source\ncopy contents 1 1 1\nPRIVATE_ROW\ncopy prod\ncopy contents 1 1 1\ncopy ok\n', ''
        return super().handle(command, stdin)


def operator(fake, **changes):
    original = b.BootstrapTests().operator(fake)
    op = m.Copy.__new__(m.Copy)
    op.__dict__.update(original.__dict__)
    for key, value in changes.items():
        setattr(op.args, key, value)
    return op


class Lifecycle(unittest.TestCase):
    def execute(self, fake, **changes):
        op = operator(fake, **changes)
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(out), patch.object(m.time, 'sleep'):
            try:
                result, error = op.execute(), None
            except (m.SafeError, KeyboardInterrupt) as e:
                result, error = None, e
        self.assertNotIn(b.MASTER_PW, out.getvalue())
        self.assertNotIn(b.LEAK, out.getvalue())
        self.assertNotIn('PRIVATE_ROW', out.getvalue())
        self.assertFalse(any(b.MASTER_PW in ' '.join(c) or b.LEAK in ' '.join(c) for c in fake.calls))
        return result, error, out.getvalue()

    def test_success_and_only_copy_resources_cleaned(self):
        fake = Cluster()
        fake.objects['secret/db-bootstrap-prod-master'] = 'foreign-bootstrap'
        rc, error, _ = self.execute(fake)
        self.assertEqual((rc, error), (0, None))
        self.assertEqual(fake.objects, {'secret/db-bootstrap-prod-master': 'foreign-bootstrap'})
        self.assertIsNone(fake.lease)
        self.assertEqual(fake.created, ['configmap/' + m.CONFIGMAP, 'secret/' + m.MASTER_SECRET, 'job/' + m.JOB])
        self.assertTrue(any('--cli-input-json' in c for c in fake.calls))
        self.assertFalse(any('--secret-id' in c for c in fake.calls))  # no unrelated prod bundle read
        lock = next(i for i, s in enumerate(fake.stdins) if s and '"kind": "Lease"' in s)
        credential = next(i for i, c in enumerate(fake.calls) if '--cli-input-json' in c)
        self.assertLess(lock, credential)

    def test_check_never_fetches_master_or_mutates(self):
        fake = Cluster()
        rc, error, output = self.execute(fake, action='check')
        self.assertEqual((rc, error), (0, None))
        self.assertIn('DB는 조회하지 않았습니다', output)
        self.assertFalse(any('--cli-input-json' in c for c in fake.calls))
        self.assertFalse(any(c[0] == 'kubectl' and c[6] in ['create', 'replace', 'delete'] for c in fake.calls))

    def test_confirmation_before_preflight(self):
        fake = Cluster()
        _, error, _ = self.execute(fake, confirm_env=None)
        self.assertIsInstance(error, m.SafeError)
        self.assertFalse(fake.calls)

    def test_shared_bootstrap_lock_blocks_before_credential(self):
        fake = Cluster(lease={'holderIdentity': 'other-bootstrap', 'acquireTime': b.module.micro_time()})
        _, error, _ = self.execute(fake)
        self.assertIsInstance(error, m.SafeError)
        self.assertEqual(fake.deleted, [])
        self.assertFalse(any('--cli-input-json' in c for c in fake.calls))

    def test_copy_holds_same_lock_against_bootstrap(self):
        fake = Cluster()
        op = operator(fake)
        boot = b.BootstrapTests().operator(fake)
        original = op.wait_job
        def wait():
            before = dict(fake.objects)
            with self.assertRaises(m.SafeError):
                boot.execute()
            self.assertEqual(fake.objects, before)
            return original()
        op.wait_job = wait
        with redirect_stdout(io.StringIO()), patch.object(m.time, 'sleep'):
            self.assertEqual(op.execute(), 0)

    def test_failures_cleanup_and_preserve_original_error(self):
        for state in ['failed', 'timeout', 'interrupt']:
            with self.subTest(state=state):
                fake = Cluster(job_result=state)
                _, error, _ = self.execute(fake)
                self.assertIsNotNone(error)
                self.assertEqual(fake.objects, {})
                self.assertIsNone(fake.lease)

    def test_cleanup_failure_wins_and_retains_lock(self):
        for state in ['ok', 'failed', 'interrupt']:
            with self.subTest(state=state):
                fake = Cluster(stuck=['secret/' + m.MASTER_SECRET], job_result=state)
                rc, error, _ = self.execute(fake)
                self.assertEqual((rc, error), (3, None))
                self.assertIn('secret/' + m.MASTER_SECRET, fake.objects)
                self.assertIsNotNone(fake.lease)

    def test_create_failure_and_cleanup_failure_code3(self):
        fake = Cluster(stuck=['secret/' + m.MASTER_SECRET], fail_create='job/' + m.JOB)
        rc, error, _ = self.execute(fake)
        self.assertEqual((rc, error), (3, None))
        self.assertIsNotNone(fake.lease)

    def test_leftover_failure_stops_before_new_credentials(self):
        fake = Cluster(leftovers={'secret/' + m.MASTER_SECRET: 'old'}, stuck=['secret/' + m.MASTER_SECRET])
        rc, error, _ = self.execute(fake)
        self.assertEqual((rc, error), (3, None))
        self.assertFalse(any('--cli-input-json' in c for c in fake.calls))

    def test_cleanup_exception_returns3_and_keeps_lease(self):
        fake = Cluster()
        op = operator(fake)
        original = op.cleanup
        def cleanup(run_id):
            if run_id is not None:
                raise ValueError('unexpected API shape')
            return original(run_id)
        op.cleanup = cleanup
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(m.time, 'sleep'):
            self.assertEqual(op.execute(), 3)
        self.assertIsNotNone(fake.lease)

    def test_lease_release_exception_is_failure_after_credentials_are_gone(self):
        fake = Cluster()
        op = operator(fake)
        op.release_lock = lambda: (_ for _ in ()).throw(ValueError('unexpected lease shape'))
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(m.time, 'sleep'):
            self.assertEqual(op.execute(), 1)
        self.assertEqual(fake.objects, {})

    def test_log_allowlist_numeric_only(self):
        self.assertEqual(m.safe_log('copy ok\ncopy embeddings 1 2 3 4\ncopy runs 1 -1 3 0\ncopy contents secret\nSECRET'),
                         'copy ok\ncopy embeddings 1 2 3 4\ncopy runs 1 -1 3 0')

    def test_template_and_config_no_unresolved_placeholders(self):
        result = m.manifest(b.HOST, 'a' * 32)
        self.assertNotIn('RUN_ID', result)
        self.assertNotIn('RDS_ENDPOINT', result)
        self.assertIn('fsGroup: 999', result)
        self.assertIn('readOnlyRootFilesystem: true', result)
        self.assertIn('sizeLimit: 2Gi', result)
        payload = json.loads(m.configmap('a' * 32))['data']
        self.assertEqual(set(payload), set(m.PAYLOADS))
        self.assertIn('session_replication_role=replica', payload['run-copy.sh'])
        self.assertIn('--data-only', payload['run-copy.sh'])
        self.assertNotIn('--clean', payload['run-copy.sh'])

    def test_copy_policy_and_seed_user_exclusions(self):
        policy = (m.DIRECTORY / 'policy.sql').read_text()
        modes = re.findall(r"\('(copy|seed|ignored)', '([^']+)'\)", policy)
        self.assertEqual(sum(mode == 'copy' for mode, _ in modes), 15)
        self.assertIn(('seed', 'rag.rerank_policies'), modes)
        self.assertIn(('ignored', 'catalog.flyway_schema_history'), modes)
        self.assertIn(('ignored', 'catalog.recent_searches'), modes)


if __name__ == '__main__':
    unittest.main()
