"""Argo CD installer boundaries; no AWS, cluster, or download access."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

scripts = Path(__file__).resolve().parents[2] / "scripts/eks"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("bootstrap_argocd", scripts / "bootstrap_argocd.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.operator = module.Bootstrap.__new__(module.Bootstrap)
        self.operator.args = SimpleNamespace(action="check", cluster_name="ureka-eks", context="ureka-eks",
                                             confirm_cluster=None)
        self.operator.env = {}
        self.operator.identity = Mock(return_value={"Account": "000000000000"})
        self.cluster = {"arn": "arn:aws:eks:ap-northeast-2:000000000000:cluster/ureka-eks",
                        "status": "ACTIVE", "endpoint": "https://example.invalid"}
        self.config = {"contexts": [{"context": {"cluster": "expected"}}],
                       "clusters": [{"name": "expected", "cluster": {"server": "https://example.invalid"}}]}

    def tearDown(self):
        self.tmp.cleanup()

    def test_context_mismatch_and_wrong_account_rejected(self):
        module.verify_destination(self.cluster, self.config, "000000000000")
        self.config["clusters"][0]["cluster"]["server"] = "https://wrong.invalid"
        with self.assertRaises(module.SafeError):
            module.verify_destination(self.cluster, self.config, "000000000000")
        with self.assertRaises(module.SafeError):
            module.verify_destination(self.cluster, self.config, "other")

    def test_checksum_mismatch_is_fatal(self):
        with self.assertRaises(module.SafeError):
            module.verify_manifest(b"modified upstream")

    def test_not_ready_nodes_stop_before_download(self):
        self.operator.aws = Mock(return_value={"cluster": self.cluster})
        self.operator.run = Mock(side_effect=[json.dumps(self.config), json.dumps({"items": []})])
        with patch.object(module.urllib.request, "urlopen") as download:
            with self.assertRaises(module.SafeError):
                self.operator.preflight()
            download.assert_not_called()

    def test_check_never_installs(self):
        self.operator.preflight = Mock(return_value=self.root / "manifest.yaml")
        self.operator.install_step = Mock()
        with redirect_stdout(io.StringIO()):
            self.operator.execute()
        self.operator.install_step.assert_not_called()

    def test_install_requires_confirmation_before_cluster_access(self):
        self.operator.args.action = "install"
        self.operator.preflight = Mock()
        with self.assertRaises(module.SafeError):
            self.operator.execute()
        self.operator.preflight.assert_not_called()

    def test_unmerged_code_blocks_install(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.run = Mock(side_effect=["", "changed.py"])
        self.operator.preflight = Mock()
        with self.assertRaises(module.SafeError):
            self.operator.execute()
        self.operator.preflight.assert_not_called()

    def test_partial_failure_retains_lock_and_per_run_result(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.merged_code = Mock()
        manifest = self.root / "manifest.yaml"
        self.operator.preflight = Mock(return_value=manifest)
        self.operator.install_step = Mock(side_effect=module.SafeError("synthetic failure"))
        with redirect_stdout(io.StringIO()), self.assertRaises(module.SafeError):
            self.operator.execute()
        self.assertTrue((self.root / "in-progress").exists())
        result = next(self.root.glob("run-*/result.json"))
        self.assertFalse(json.loads(result.read_text())["success"])
        self.assertEqual(result.stat().st_mode & 0o777, 0o600)

    def test_success_installs_no_app_secret_db_or_external_service(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.merged_code = Mock()
        self.operator.preflight = Mock(return_value=self.root / "manifest.yaml")
        self.operator.install_step = Mock()
        with patch.object(module, "ROOT", self.root), redirect_stdout(io.StringIO()):
            self.operator.execute()
        commands = [call.args[0] for call in self.operator.install_step.call_args_list]
        self.assertEqual(len(commands), 6)
        self.assertTrue(all(cmd[:3] == ["kubectl", "--context", "ureka-eks"] for cmd in commands))
        self.assertFalse(any("--force-conflicts" in cmd for cmd in commands))
        self.assertFalse((self.root / "in-progress").exists())
        self.assertTrue(json.loads(next(self.root.glob("run-*/result.json")).read_text())["success"])

    def test_private_live_log_does_not_echo_output(self):
        process = Mock()
        process.wait.side_effect = [module.subprocess.TimeoutExpired("synthetic", 30), 0]
        def popen(*args, **kwargs):
            kwargs["stdout"].write(b"synthetic private log")
            kwargs["stdout"].flush()
            manager = Mock()
            manager.__enter__ = Mock(return_value=process)
            manager.__exit__ = Mock(return_value=False)
            return manager
        output = io.StringIO()
        log = self.root / "step.log"
        with patch.object(module.subprocess, "Popen", side_effect=popen), redirect_stdout(output):
            self.operator.install_step(["synthetic"], log)
        self.assertEqual(log.read_bytes(), b"synthetic private log")
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("synthetic private log", output.getvalue())
        self.assertIn("진행 중", output.getvalue())


if __name__ == "__main__":
    unittest.main()
