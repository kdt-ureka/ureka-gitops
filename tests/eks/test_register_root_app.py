"""EKS root app registration boundaries (#43); no AWS or cluster access."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

scripts = Path(__file__).resolve().parents[2] / "scripts/eks"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("register_root_app", scripts / "register_root_app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ACCOUNT = "000000000000"
REGISTRY = f"{ACCOUNT}.dkr.ecr.ap-northeast-2.amazonaws.com"


def done(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class InjectTests(unittest.TestCase):
    def test_git_manifest_has_exactly_one_blank(self):
        source = module.MANIFEST.read_text()
        self.assertEqual(source.count(module.BLANK), 1)
        self.assertNotRegex(source, r"[0-9]{12}")

    def test_injects_registry_once(self):
        out = module.inject_registry(module.MANIFEST.read_text(), ACCOUNT)
        self.assertEqual(out.count(REGISTRY), 1)
        self.assertNotIn(module.BLANK, out)

    def test_rejects_bad_account(self):
        for bad in ("", "12345", "00000000000a", "0000000000000", None):
            with self.assertRaises(module.SafeError):
                module.inject_registry(module.MANIFEST.read_text(), bad)

    def test_rejects_missing_or_duplicate_blank(self):
        source = module.MANIFEST.read_text()
        with self.assertRaises(module.SafeError):
            module.inject_registry(source.replace(module.BLANK, ""), ACCOUNT)
        with self.assertRaises(module.SafeError):
            module.inject_registry(source + module.BLANK, ACCOUNT)
        with self.assertRaises(module.SafeError):  # a value already in Git
            module.inject_registry(module.inject_registry(source, ACCOUNT), ACCOUNT)


class RegisterTests(unittest.TestCase):
    def make(self, action="check", confirm=None):
        reg = module.Register.__new__(module.Register)
        reg.args = SimpleNamespace(action=action, cluster_name="ureka-eks", context="ureka-eks",
                                   confirm_cluster=confirm)
        reg.env = {}
        return reg

    def test_apply_requires_confirm_before_any_call(self):
        reg = self.make("apply", confirm="other")
        reg.preflight = Mock()
        with patch.object(module.subprocess, "run") as run:
            with self.assertRaises(module.SafeError):
                reg.execute()
        reg.preflight.assert_not_called()
        run.assert_not_called()

    def run_execute(self, action, confirm=None, result=None):
        reg = self.make(action, confirm)
        reg.preflight = Mock(return_value=module.inject_registry(module.MANIFEST.read_text(), ACCOUNT))
        out, err = io.StringIO(), io.StringIO()
        with patch.object(module.subprocess, "run", return_value=result or done()) as run, \
                redirect_stdout(out), redirect_stderr(err):
            try:
                reg.execute()
                error = None
            except module.SafeError as e:
                error = e
        return run, out.getvalue() + err.getvalue(), error

    def test_check_is_server_dry_run_with_registry_only_on_stdin(self):
        run, printed, error = self.run_execute("check")
        self.assertIsNone(error)
        argv = run.call_args.args[0]
        self.assertIn("--dry-run=server", argv)
        self.assertEqual(argv[-2:], ["-f", "-"])
        self.assertEqual(argv[:3], ["kubectl", "--context", "ureka-eks"])
        self.assertFalse(any(ACCOUNT in a for a in argv))
        self.assertIn(REGISTRY, run.call_args.kwargs["input"])
        self.assertNotIn(ACCOUNT, printed)

    def test_apply_has_no_dry_run(self):
        run, printed, error = self.run_execute("apply", confirm="ureka-eks")
        self.assertIsNone(error)
        self.assertNotIn("--dry-run=server", run.call_args.args[0])
        self.assertNotIn(ACCOUNT, printed)

    def test_failure_never_echoes_kubectl_output(self):
        leak = done(1, stdout=REGISTRY, stderr=f"error: {REGISTRY}")
        run, printed, error = self.run_execute("apply", confirm="ureka-eks", result=leak)
        self.assertIsInstance(error, module.SafeError)
        self.assertNotIn(ACCOUNT, str(error) + printed)

    def preflight_with(self, crd_results):
        reg = self.make()
        reg.identity = Mock(return_value={"Account": ACCOUNT})
        reg.aws = Mock(return_value={"cluster": {}})
        reg.run = Mock(return_value="{}")
        return reg, patch.object(module, "verify_destination"), \
            patch.object(module.subprocess, "run", side_effect=crd_results)

    def test_preflight_stops_without_rollouts_crd(self):
        reg, vd, run = self.preflight_with([done(), done(), done(1, stderr="Error (NotFound)")])
        with vd, run, self.assertRaises(module.SafeError) as ctx:
            reg.preflight()
        self.assertIn("rollouts.argoproj.io", str(ctx.exception))

    def test_preflight_does_not_treat_errors_as_missing(self):
        reg, vd, run = self.preflight_with([done(1, stderr="Forbidden")])
        with vd, run, self.assertRaises(module.SafeError) as ctx:
            reg.preflight()
        self.assertIn("조회 실패", str(ctx.exception))

    def test_preflight_ok_returns_injected_manifest(self):
        reg, vd, run = self.preflight_with([done(), done(), done()])
        with vd as verify, run:
            out = reg.preflight()
        verify.assert_called_once()
        self.assertIn(REGISTRY, out)


class MainTests(unittest.TestCase):
    def test_account_id_is_not_an_argument(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            with patch.object(sys, "argv", ["x", "check", "--profile", "p", "--expected-account-id", ACCOUNT]):
                module.main()

    def test_missing_or_bad_env_stops_before_aws(self):
        for value in (None, "", "123"):
            env = {} if value is None else {"UREKA_EXPECTED_ACCOUNT_ID": value}
            err = io.StringIO()
            with patch.dict(module.os.environ, env, clear=True), patch.object(module, "Register") as reg, \
                    patch.object(sys, "argv", ["x", "check", "--profile", "p"]), redirect_stderr(err):
                self.assertEqual(module.main(), 1)
            reg.assert_not_called()
            self.assertIn("UREKA_EXPECTED_ACCOUNT_ID", err.getvalue())

    def test_env_account_is_passed_to_operator(self):
        with patch.dict(module.os.environ, {"UREKA_EXPECTED_ACCOUNT_ID": ACCOUNT}), \
                patch.object(module, "Register") as reg, patch.object(sys, "argv", ["x", "check", "--profile", "p"]):
            self.assertEqual(module.main(), 0)
        self.assertEqual(reg.call_args.args[0].expected_account_id, ACCOUNT)


if __name__ == "__main__":
    unittest.main()
