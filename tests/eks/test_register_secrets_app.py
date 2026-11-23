"""EKS secrets Application registration (#63): no AWS or cluster access."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

scripts = Path(__file__).resolve().parents[2] / "scripts/eks"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("register_secrets_app", scripts / "register_secrets_app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ACCOUNT = "000000000000"


class RegisterTests(unittest.TestCase):
    def operator(self, action="check", env="dev", confirm=None):
        op = module.Register.__new__(module.Register)
        op.args = SimpleNamespace(action=action, env=env, confirm_env=confirm, cluster_name="ureka-eks",
                                  context="ureka-eks", expected_account_id=ACCOUNT)
        op.env = {}
        op.identity = Mock(return_value={"Account": ACCOUNT})
        op.aws = Mock(return_value={"cluster": {"arn": f"arn:aws:eks:ap-northeast-2:{ACCOUNT}:cluster/ureka-eks",
                                                "status": "ACTIVE", "endpoint": "https://example.invalid"}})
        op.run = Mock(return_value='{"current-context": "ureka-eks", "contexts": [{"context": {"cluster": "c"}}],'
                                   ' "clusters": [{"name": "c", "cluster": {"server": "https://example.invalid"}}]}')
        return op

    def test_git_manifests_keep_the_account_blank(self):
        for env in ("dev", "prod"):
            text = module.manifest_path(env).read_text()
            self.assertEqual(text.count(module.BLANK), 1)
            self.assertIn(f"namespace: {env}", text)
            self.assertIn(f"environments/eks/{env}/secrets.yaml", text)

    def test_inject_requires_twelve_digits_and_single_blank(self):
        source = module.manifest_path("dev").read_text()
        self.assertIn(f'value: "{ACCOUNT}"', module.inject_account(source, ACCOUNT))
        for bad in ("", "12345", "abcdefghijkl", "0000000000001"):
            with self.assertRaises(module.SafeError):
                module.inject_account(source, bad)
        with self.assertRaises(module.SafeError):
            module.inject_account(source.replace(module.BLANK, ""), ACCOUNT)

    def test_apply_requires_explicit_environment(self):
        op = self.operator(action="apply", env="prod", confirm="dev")
        op.preflight = Mock()
        with self.assertRaisesRegex(module.SafeError, "--confirm-env"):
            op.execute()
        op.preflight.assert_not_called()

    def test_cluster_wide_store_crd_stops(self):
        op = self.operator()
        op.exists = Mock(side_effect=lambda kind, name: True)
        with self.assertRaisesRegex(module.SafeError, "클러스터 범위"):
            op.preflight()

    def test_missing_namespace_stops(self):
        op = self.operator()
        op.exists = Mock(side_effect=lambda kind, name: kind == "crd" and name in module.CRDS)
        with self.assertRaisesRegex(module.SafeError, "#62"):
            op.preflight()

    def test_account_goes_only_to_stdin_and_errors_hide_it(self):
        op = self.operator(action="apply", env="dev", confirm="dev")
        op.exists = Mock(side_effect=lambda kind, name: not (kind == "crd" and name in module.FORBIDDEN_CRDS))
        calls = []

        def fake_run(command, **kwargs):
            calls.append((command, kwargs.get("input")))
            return SimpleNamespace(returncode=1, stdout=kwargs.get("input"), stderr=kwargs.get("input"))
        out = io.StringIO()
        with patch.object(module.subprocess, "run", fake_run), redirect_stdout(out), redirect_stderr(out):
            with self.assertRaises(module.SafeError) as raised:
                op.execute()
        command, stdin = calls[0]
        self.assertNotIn(ACCOUNT, " ".join(command))
        self.assertIn("--server-side", command)
        self.assertIn(f'value: "{ACCOUNT}"', stdin)
        self.assertNotIn(ACCOUNT, str(raised.exception) + out.getvalue())

    def test_account_is_read_from_environment_not_argv(self):
        with patch.object(sys, "argv", ["register", "check", "--env", "dev", "--profile", "p"]), \
                patch.dict(module.os.environ, {"UREKA_EXPECTED_ACCOUNT_ID": ""}), redirect_stderr(io.StringIO()) as err:
            self.assertEqual(module.main(), 1)
        self.assertIn("UREKA_EXPECTED_ACCOUNT_ID", err.getvalue())
        with patch.object(sys, "argv", ["register", "check", "--env", "dev", "--profile", "p",
                                        "--expected-account-id", ACCOUNT]), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                module.main()
        seen = {}

        class Fake:
            def __init__(self, args):
                seen["account"] = args.expected_account_id

            def execute(self):
                pass
        with patch.object(sys, "argv", ["register", "check", "--env", "dev", "--profile", "p"]), \
                patch.dict(module.os.environ, {"UREKA_EXPECTED_ACCOUNT_ID": ACCOUNT}), patch.object(module, "Register", Fake):
            self.assertEqual(module.main(), 0)
        self.assertEqual(seen["account"], ACCOUNT)

    def test_check_uses_server_dry_run(self):
        op = self.operator(action="check")
        op.exists = Mock(side_effect=lambda kind, name: not (kind == "crd" and name in module.FORBIDDEN_CRDS))
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        with patch.object(module.subprocess, "run", fake_run), redirect_stdout(io.StringIO()):
            op.execute()
        self.assertIn("--dry-run=server", calls[0])


if __name__ == "__main__":
    unittest.main()
