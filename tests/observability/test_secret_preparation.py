import base64
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[2]/'scripts/ec2/prepare-observability-secrets.py'

class SecretPreparation(unittest.TestCase):
    def run_script(self, existing=None, source=True, fail=False):
        writes=[]
        value=b'private-fixture-never-log'
        encoded=base64.b64encode(value).decode()
        def kube(argv, **kw):
            if 'get' in argv:
                if fail:return subprocess.CompletedProcess(argv,1,'','private-fixture-never-log')
                name=argv[argv.index('secret')+1]
                if name=='ureka-grafana-admin':data={'admin-user': 'YWRtaW4=', 'admin-password': encoded}
                elif name=='ureka-metrics-tokens':
                    if existing is None:return subprocess.CompletedProcess(argv,0,'','')
                    data={k:(encoded if existing else 'b2xk') for k in ('auth','content','chat')}
                else:data={'INTERNAL_SERVICE_TOKEN':encoded} if source else {}
                return subprocess.CompletedProcess(argv,0,json.dumps({'data':data}),'')
            writes.append(json.loads(kw['input']))
            return subprocess.CompletedProcess(argv,0,'created','')
        output=io.StringIO();error=None
        with patch('os.geteuid',return_value=0),patch('pathlib.Path.is_file',return_value=True),patch('subprocess.run',side_effect=kube),patch('sys.argv',[str(SCRIPT),'--app-metrics']),contextlib.redirect_stdout(output):
            try:runpy.run_path(str(SCRIPT),run_name='__main__')
            except SystemExit as exc:error=str(exc)
        self.assertNotIn(value.decode(), output.getvalue()+(error or ''))
        return writes,error

    def test_existing_matching_secret_is_never_replaced(self):
        writes,error=self.run_script(existing=True)
        self.assertIsNone(error);self.assertEqual(writes,[])

    def test_missing_secret_uses_stdin_data_only(self):
        writes,error=self.run_script()
        self.assertIsNone(error);self.assertEqual(len(writes),1)
        self.assertEqual(writes[0]['metadata']['namespace'],'observability')
        self.assertEqual(set(writes[0]['data']),{'auth','content','chat'})

    def test_mismatch_empty_source_and_forbidden_stop_without_overwrite(self):
        for options in ({'existing':False},{'source':False},{'fail':True}):
            writes,error=self.run_script(**options)
            self.assertIsNotNone(error);self.assertEqual(writes,[])
