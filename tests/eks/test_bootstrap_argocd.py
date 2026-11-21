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
        self.base = self.root / "argocd-bootstrap"
        self.base.mkdir()
        self.artifacts_patch = patch.object(module, "ARTIFACTS", self.root)
        self.artifacts_patch.start()
        self.operator = module.Bootstrap.__new__(module.Bootstrap)
        self.operator.args = SimpleNamespace(action="check", cluster_name="ureka-eks", context="ureka-eks",
                                             confirm_cluster=None)
        self.operator.env = {}
        self.operator.identity = Mock(return_value={"Account": "000000000000"})
        self.cluster = {"arn": "arn:aws:eks:ap-northeast-2:000000000000:cluster/ureka-eks",
                        "status": "ACTIVE", "endpoint": "https://example.invalid"}
        self.config = {"current-context": "ureka-eks", "contexts": [{"context": {"cluster": "expected"}}],
                       "clusters": [{"name": "expected", "cluster": {"server": "https://example.invalid"}}]}

    def tearDown(self):
        self.artifacts_patch.stop()
        self.tmp.cleanup()

    def prepared(self):
        folder = Path(tempfile.mkdtemp(prefix="run-", dir=self.base))
        path = folder / "rendered.yaml"
        path.write_text("synthetic complete manifest")
        return path

    def test_context_mismatch_and_wrong_account_rejected(self):
        module.verify_destination(self.cluster, self.config, "000000000000", "ureka-eks")
        self.config["clusters"][0]["cluster"]["server"] = "https://wrong.invalid"
        with self.assertRaises(module.SafeError):
            module.verify_destination(self.cluster, self.config, "000000000000", "ureka-eks")
        with self.assertRaises(module.SafeError):
            module.verify_destination(self.cluster, self.config, "other", "ureka-eks")
        self.config["clusters"][0]["cluster"]["server"] = self.cluster["endpoint"]
        self.config["current-context"] = "unexpected"
        with self.assertRaisesRegex(module.SafeError, "current-context"):
            module.verify_destination(self.cluster, self.config, "000000000000", "ureka-eks")

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
        self.operator.preflight = Mock(side_effect=self.prepared)
        self.operator.install_step = Mock(side_effect=module.SafeError("synthetic failure"))
        with redirect_stdout(io.StringIO()), self.assertRaises(module.SafeError):
            self.operator.execute()
        self.assertTrue((self.base / "in-progress").exists())
        result = next(self.base.glob("run-*/result.json"))
        self.assertFalse(json.loads(result.read_text())["success"])
        self.assertEqual(result.stat().st_mode & 0o777, 0o600)
        # A new run directory must not bypass the single shared install lock.
        calls = self.operator.install_step.call_count
        with redirect_stdout(io.StringIO()), self.assertRaisesRegex(module.SafeError, "실행 기록"):
            self.operator.execute()
        self.assertEqual(self.operator.install_step.call_count, calls)

    def test_success_installs_no_app_secret_db_or_external_service(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.merged_code = Mock()
        self.operator.preflight = Mock(side_effect=self.prepared)
        self.operator.install_step = Mock()
        with patch.object(module, "ROOT", self.root), redirect_stdout(io.StringIO()):
            self.operator.execute()
        commands = [call.args[0] for call in self.operator.install_step.call_args_list]
        self.assertEqual(len(commands), 5)
        self.assertTrue(all(cmd[:3] == ["kubectl", "--context", "ureka-eks"] for cmd in commands))
        self.assertFalse(any("--force-conflicts" in cmd for cmd in commands))
        self.assertFalse((self.base / "in-progress").exists())
        self.assertTrue(json.loads(next(self.base.glob("run-*/result.json")).read_text())["success"])

    def test_replicas_are_rendered_into_complete_manifest_before_apply(self):
        path = self.root / "install.yaml"
        path.write_text("synthetic upstream")
        self.operator.run = Mock(return_value="synthetic complete rendered resources")
        rendered = self.operator.render_manifest(path)
        config = json.loads((self.root / "kustomization.yaml").read_text())
        patches = [json.loads(item["patch"]) for item in config["patches"]]
        self.assertEqual(config["resources"], ["install.yaml"])
        self.assertEqual({p["metadata"]["name"] for p in patches},
                         {"argocd-dex-server", "argocd-notifications-controller"})
        self.assertTrue(all(p["spec"] == {"replicas": 0} for p in patches))
        self.assertEqual(rendered.read_text(), "synthetic complete rendered resources")

    def test_retry_after_partial_install_uses_same_ssa_manager_without_scale(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.merged_code = Mock()
        self.operator.preflight = Mock(side_effect=self.prepared)
        applied = []
        fail_once = [True]
        def install(command, log):
            if "rollout" in command and fail_once[0]:
                fail_once[0] = False
                raise module.SafeError("synthetic rollout failure")
            if "apply" in command:
                self.assertIn("--server-side", command)
                self.assertIn("--field-manager=ureka-eks-bootstrap", command)
                self.assertNotIn("scale", command)
                applied.append(command)
        self.operator.install_step = install
        with patch.object(module, "ROOT", self.root), redirect_stdout(io.StringIO()):
            with self.assertRaises(module.SafeError):
                self.operator.execute()
            self.assertTrue((self.base / "in-progress").exists())
            # Simulate deliberate lock removal after the operator inspected the failure.
            (self.base / "in-progress").unlink()
            self.operator.execute()
        self.assertEqual(applied[0], applied[2])
        self.assertEqual(applied[1][:-1], applied[3][:-1])
        self.assertNotEqual(applied[1][-1], applied[3][-1])
        self.assertEqual(Path(applied[1][-1]).read_bytes(), Path(applied[3][-1]).read_bytes())
        self.assertEqual(len(list(self.base.glob("run-*/result.json"))), 2)
        self.assertFalse((self.base / "in-progress").exists())

    def test_check_during_install_cannot_overwrite_install_inputs(self):
        self.operator.args.action = "install"
        self.operator.args.confirm_cluster = "ureka-eks"
        self.operator.merged_code = Mock()
        self.operator.aws = Mock(return_value={"cluster": self.cluster})
        render_count = [0]
        def read_only(command):
            if "config" in command:
                return json.dumps(self.config)
            if "nodes" in command:
                return json.dumps({"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}] * 2})
            if "kustomize" in command:
                render_count[0] += 1
                return f"synthetic rendered run {render_count[0]}"
            raise AssertionError("unexpected command")
        self.operator.run = read_only
        payload = b"synthetic fixed upstream"
        response = Mock()
        response.__enter__ = Mock(return_value=Mock(read=Mock(return_value=payload)))
        response.__exit__ = Mock(return_value=False)
        checked_paths = []
        def installing(command, log):
            if "apply" not in command or "argocd" not in command:
                return
            install_path = Path(command[-1])
            snapshot = {p.name: p.read_bytes() for p in install_path.parent.iterdir() if p.is_file()}
            self.assertTrue((self.base / "in-progress").exists())
            self.operator.args.action = "check"
            try:
                self.operator.execute()
            finally:
                self.operator.args.action = "install"
            # Check finishes while install's shared lock is held, but all install inputs stay intact.
            self.assertEqual(snapshot, {p.name: p.read_bytes() for p in install_path.parent.iterdir() if p.is_file()})
            other = [p for p in self.base.glob("run-*/rendered.yaml") if p != install_path]
            self.assertEqual(len(other), 1)
            self.assertNotEqual(install_path.read_bytes(), other[0].read_bytes())
            self.assertEqual(install_path.parent.stat().st_mode & 0o777, 0o700)
            checked_paths.append(install_path)
        self.operator.install_step = installing
        with patch.object(module, "ROOT", self.root), patch.object(module, "SHA256", hashlib.sha256(payload).hexdigest()), \
             patch.object(module.urllib.request, "urlopen", return_value=response), redirect_stdout(io.StringIO()):
            self.operator.execute()
        self.assertEqual(len(checked_paths), 1)
        self.assertEqual(render_count[0], 2)

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
