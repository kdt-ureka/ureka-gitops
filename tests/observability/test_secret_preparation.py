import base64
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/ec2/prepare-observability-secrets.py'
BUSINESS = b'business-fixture-never-copy'
TOKENS = {s: f'scrape-{s}-fixture-never-log'.encode() for s in ('auth', 'content', 'chat')}

def enc(value):
    return base64.b64encode(value).decode()

class SecretPreparation(unittest.TestCase):
    def run_script(self, dedicated=True, collector=None, bad=None, forbidden=False, chat=False):
        writes = []
        def kube(argv, **kw):
            self.assertNotIn(BUSINESS.decode(), ' '.join(argv))
            if 'get' in argv:
                if forbidden:
                    return subprocess.CompletedProcess(argv, 1, '', BUSINESS.decode())
                name = argv[argv.index('secret') + 1]
                if name == 'ureka-grafana-admin':
                    data = {'admin-user': enc(b'admin'), 'admin-password': enc(b'admin-fixture')}
                elif name == 'ureka-metrics-tokens':
                    if collector is None:
                        return subprocess.CompletedProcess(argv, 0, '', '')
                    services = ('auth', 'content', 'chat') if chat else ('auth', 'content')
                    data = {s: enc(TOKENS[s] if collector else b'old') for s in services}
                elif name.endswith('-secrets'):
                    data = {'INTERNAL_SERVICE_TOKEN': enc(BUSINESS)}
                else:
                    service = name.split('-')[1]
                    if not dedicated:
                        return subprocess.CompletedProcess(argv, 0, '', '')
                    value = TOKENS[service]
                    if bad == 'business':
                        value = BUSINESS
                    elif bad == 'empty':
                        value = b''
                    elif bad == 'duplicate':
                        value = TOKENS['auth']
                    elif bad == 'whitespace':
                        value = b' '
                    data = {'METRICS_SCRAPE_TOKEN': 'not-base64!' if bad == 'base64' else enc(value)}
                return subprocess.CompletedProcess(argv, 0, json.dumps({'data': data}), '')
            writes.append(json.loads(kw['input']))
            return subprocess.CompletedProcess(argv, 0, 'created', '')

        output, error = io.StringIO(), None
        argv = [str(SCRIPT), '--app-metrics'] + (['--chat-metrics'] if chat else [])
        generated = iter(['generated-auth-token', 'generated-content-token', 'generated-chat-token'])
        with patch('os.geteuid', return_value=0), patch('pathlib.Path.is_file', return_value=True), \
             patch('subprocess.run', side_effect=kube), patch('sys.argv', argv), \
             patch('secrets.token_urlsafe', side_effect=lambda n: next(generated)), contextlib.redirect_stdout(output):
            try:
                runpy.run_path(str(SCRIPT), run_name='__main__')
            except SystemExit as exc:
                error = str(exc)
        for value in [BUSINESS, *TOKENS.values()]:
            self.assertNotIn(value.decode(), output.getvalue() + (error or ''))
        return writes, error

    def test_matching_secrets_are_never_replaced(self):
        writes, error = self.run_script(collector=True)
        self.assertIsNone(error)
        self.assertEqual(writes, [])

    def test_new_dedicated_credentials_are_not_copied_from_business(self):
        writes, error = self.run_script(dedicated=False)
        self.assertIsNone(error)
        self.assertEqual(len(writes), 3)
        self.assertEqual([m['metadata']['namespace'] for m in writes], ['dev', 'dev', 'observability'])
        for m in writes[:2]:
            self.assertEqual(set(m['data']), {'METRICS_SCRAPE_TOKEN'})
            self.assertNotEqual(m['data']['METRICS_SCRAPE_TOKEN'], enc(BUSINESS))
        self.assertEqual(set(writes[-1]['data']), {'auth', 'content'})
        self.assertEqual(writes[-1]['data']['auth'], writes[0]['data']['METRICS_SCRAPE_TOKEN'])
        self.assertEqual(writes[-1]['data']['content'], writes[1]['data']['METRICS_SCRAPE_TOKEN'])

    def test_collector_uses_existing_dedicated_values_only(self):
        writes, error = self.run_script()
        self.assertIsNone(error)
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]['data'], {s: enc(TOKENS[s]) for s in ('auth', 'content')})

    def test_business_empty_duplicate_malformed_values_fail_before_writes(self):
        for bad in ('business', 'empty', 'duplicate', 'base64', 'whitespace'):
            with self.subTest(bad=bad):
                writes, error = self.run_script(bad=bad)
                self.assertIsNotNone(error)
                self.assertEqual(writes, [])

    def test_mismatch_or_forbidden_fail_without_overwrite_or_secret_output(self):
        for options in ({'collector': False}, {'forbidden': True}):
            writes, error = self.run_script(**options)
            self.assertIsNotNone(error)
            self.assertEqual(writes, [])

    def test_chat_is_opt_in_and_uses_dedicated_credentials(self):
        writes, error = self.run_script(chat=True)
        self.assertIsNone(error)
        self.assertEqual(set(writes[0]['data']), {'auth', 'content', 'chat'})
        self.assertEqual(writes[0]['data']['chat'], enc(TOKENS['chat']))
