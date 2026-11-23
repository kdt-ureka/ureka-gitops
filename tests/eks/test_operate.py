"""Safety boundary tests; no AWS/Terraform processes are launched."""
import argparse
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("operate", Path(__file__).resolve().parents[2] / "scripts/eks/operate.py")
op = importlib.util.module_from_spec(spec)
spec.loader.exec_module(op)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.patches = [patch.object(op, "ARTIFACTS", self.root), patch.object(op, "ROOT", self.root),
                        patch.dict(os.environ, {}, clear=True)]
        for p in self.patches:
            p.start()
        self.args = argparse.Namespace(profile="test", expected_account_id="000000000000",
                                       confirm_cleanup="test-cluster", review_dir=None, confirm=None)
        self.operator = op.Operator(self.args)

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    def review(self):
        folder = self.root / "review-test"
        folder.mkdir()
        (folder / "saved.tfplan").write_bytes(b"mock plan")
        review = dict(source="source", plan_sha256=op.digest(folder / "saved.tfplan"),
                      account=self.args.expected_account_id, principal="test-role", created=100,
                      destroy=False, counts={"create": 1, "update": 0, "delete": 0})
        (folder / "review.json").write_text(json.dumps(review))
        self.args.review_dir = str(folder)
        self.args.confirm = hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest()
        return folder, review

    def test_changed_plan_source_account_token_and_age_rejected(self):
        folder, review = self.review()
        correct = dict(source="source", plan_hash=op.digest(folder / "saved.tfplan"),
                       account=self.args.expected_account_id, now=101, token=self.args.confirm)
        op.checked_review(review, **correct)
        for changes in ({"source": "changed"}, {"plan_hash": "changed"}, {"account": "other"},
                        {"token": "wrong"}, {"now": 3701}, {"now": 99}):
            with self.subTest(changes=changes), self.assertRaises(op.SafeError):
                op.checked_review(review, **(correct | changes))

    def test_create_plan_rejects_replacement(self):
        with self.assertRaises(op.SafeError):
            op.summarize({"resource_changes": [{"change": {"actions": ["delete", "create"]}}]}, False)

    def test_destroy_rejects_update_and_partial_plan(self):
        for plan in ({"complete": False}, {"errored": True},
                     {"resource_changes": [{"change": {"actions": ["update"]}}]}):
            with self.subTest(plan=plan), self.assertRaises(op.SafeError):
                op.summarize(plan, True)

    def test_wrong_account_stops_before_terraform(self):
        with patch.object(self.operator, "aws", return_value={"Account": "other"}), \
             patch.object(self.operator, "init") as init:
            with self.assertRaises(op.SafeError):
                self.operator.plan()
            init.assert_not_called()

    def test_environment_overrides_rejected(self):
        for key in ("TF_CLI_ARGS_plan", "TF_VAR_admin_role_arn", "TF_WORKSPACE", "TF_DATA_DIR", "TF_PLUGIN_CACHE_DIR"):
            with patch.dict(os.environ, {key: "unexpected"}), self.assertRaises(op.SafeError):
                op.Operator(self.args)

    def test_static_credentials_removed_from_child_environment(self):
        with patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "synthetic", "AWS_SECRET_ACCESS_KEY": "synthetic"}):
            instance = op.Operator(self.args)
            self.assertNotIn("AWS_ACCESS_KEY_ID", instance.env)
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", instance.env)
            self.assertEqual(instance.env["AWS_PROFILE"], "test")

    def test_external_sg_reference_blocks_destroy(self):
        self.operator.tf = lambda *args: json.dumps({"cluster_name": {"value": "test-cluster"},
                                                     "node_security_group_id": {"value": "node"}})
        def aws(*args):
            if args[0] == "eks":
                return {"cluster": {"resourcesVpcConfig": {"clusterSecurityGroupId": "cluster"}}}
            return {"SecurityGroups": [{"GroupId": "node"}, {"GroupId": "cluster"}, {"GroupId": "rds"}]}
        self.operator.aws = aws
        with self.assertRaises(op.SafeError):
            self.operator.cleanup_gate()

    def alb_aws(self, tags):
        def aws(*args, payload=None):
            if args[0] == "eks":
                return {"cluster": {"resourcesVpcConfig": {"clusterSecurityGroupId": "cluster", "vpcId": "vpc-1"}}}
            if args[0] == "ec2":
                return {"SecurityGroups": [{"GroupId": "node"}]}
            if args[1] == "describe-load-balancers":
                return {"LoadBalancers": [{"LoadBalancerArn": "arn-a", "VpcId": "vpc-1"},
                                          {"LoadBalancerArn": "arn-other-vpc", "VpcId": "vpc-2"}]}
            # ARN(계정 ID 포함)은 명령 인자가 아니라 표준 입력 JSON으로만.
            self.assertEqual(args, ("elbv2", "describe-tags"))
            self.assertEqual(payload, {"ResourceArns": ["arn-a"]})
            return {"TagDescriptions": [{"ResourceArn": "arn-a", "Tags": tags}]}
        return aws

    def test_controller_alb_left_blocks_destroy(self):
        self.operator.tf = lambda *args: json.dumps({"cluster_name": {"value": "test-cluster"},
                                                     "node_security_group_id": {"value": "node"}})
        self.operator.aws = self.alb_aws([{"Key": "elbv2.k8s.aws/cluster", "Value": "test-cluster"}])
        with self.assertRaises(op.SafeError):
            self.operator.cleanup_gate()

    def test_unrelated_alb_does_not_block_destroy(self):
        self.operator.tf = lambda *args: json.dumps({"cluster_name": {"value": "test-cluster"},
                                                     "node_security_group_id": {"value": "node"}})
        self.operator.aws = self.alb_aws([{"Key": "elbv2.k8s.aws/cluster", "Value": "another-cluster"}])
        self.operator.cleanup_gate()

    def test_aws_payload_goes_to_private_temp_file_not_argv(self):
        calls = []

        def fake_run(command, stdin=None):
            path = command[command.index("--cli-input-json") + 1][len("file://"):]
            calls.append((command, stdin, path, os.stat(path).st_mode & 0o777, Path(path).read_text()))
            return "{}"

        self.operator.run = fake_run
        self.operator.aws("elbv2", "describe-tags", payload={"ResourceArns": ["arn:aws:x:000000000000:y"]})
        command, stdin, path, mode, body = calls[0]
        self.assertFalse(any("000000000000" in part for part in command))
        self.assertFalse(any("/dev/stdin" in part for part in command))
        self.assertIsNone(stdin)
        self.assertEqual(mode, 0o600)
        self.assertEqual(Path(path).parent, self.root)
        self.assertIn("000000000000", body)
        self.assertFalse(Path(path).exists())  # 호출 뒤 바로 삭제

    def test_temp_input_file_is_removed_when_command_fails(self):
        seen = []

        def failing_run(command, stdin=None):
            seen.append(command[command.index("--cli-input-json") + 1][len("file://"):])
            raise op.SafeError("실패")

        self.operator.run = failing_run
        with self.assertRaises(op.SafeError):
            self.operator.aws("elbv2", "describe-tags", payload={"ResourceArns": ["x"]})
        self.assertFalse(Path(seen[0]).exists())


    def test_destroy_requires_explicit_cleanup_confirmation(self):
        self.args.confirm_cleanup = None
        self.operator.tf = lambda *args: json.dumps({"cluster_name": {"value": "test-cluster"},
                                                     "node_security_group_id": {"value": "node"}})
        with self.assertRaises(op.SafeError):
            self.operator.cleanup_gate()

    def apply_mocks(self):
        self.operator.identity = lambda: {"Account": self.args.expected_account_id, "Arn": "test-role"}
        self.operator.init = lambda: None
        self.operator.run = lambda cmd: ""

    def test_changed_plan_never_applied(self):
        folder, _ = self.review()
        (folder / "saved.tfplan").write_bytes(b"modified")
        self.apply_mocks()
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf") as tf:
            with self.assertRaises(op.SafeError):
                self.operator.apply()
            tf.assert_not_called()

    def test_unmerged_code_never_applied(self):
        self.review()
        self.apply_mocks()
        self.operator.run = lambda cmd: "changed.tf" if "diff" in cmd else ""
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf") as tf:
            with self.assertRaises(op.SafeError):
                self.operator.apply()
            tf.assert_not_called()

    def test_partial_apply_cannot_be_retried(self):
        folder, _ = self.review()
        self.apply_mocks()
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf", side_effect=op.SafeError("synthetic failure")) as tf:
            with self.assertRaises(op.SafeError):
                self.operator.apply()
            self.assertTrue((folder / "attempted").exists())
            with self.assertRaises(op.SafeError):
                self.operator.apply()
            self.assertEqual(tf.call_count, 1)

    def test_valid_apply_uses_saved_plan_and_private_log(self):
        folder, _ = self.review()
        self.apply_mocks()
        def streamed_tf(*args, log_path):
            log_path.write_text("synthetic apply log")
            log_path.chmod(0o600)
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf", side_effect=streamed_tf) as tf:
            self.operator.apply()
            self.assertEqual(tf.call_args.args[-1], str(folder / "saved.tfplan"))
            self.assertEqual((folder / "apply.log").stat().st_mode & 0o777, 0o600)

    def test_dirty_checkout_never_applied(self):
        self.review()
        self.apply_mocks()
        self.operator.run = lambda cmd: " M tracked.py" if "status" in cmd else ""
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf") as tf:
            with self.assertRaises(op.SafeError):
                self.operator.apply()
            tf.assert_not_called()

    def test_source_digest_detects_private_settings_and_override_changes(self):
        stack = self.root / "infra/environments/eks"
        stack.mkdir(parents=True)
        runner = self.root / "scripts/eks/operate.py"
        runner.parent.mkdir(parents=True)
        runner.write_text("mock runner")
        for name in ("main.tf", "backend.hcl", ".terraform.lock.hcl", "terraform.tfvars"):
            (stack / name).write_text("synthetic")
        with patch.object(op, "STACK", stack), patch.object(op, "__file__", str(runner)):
            before = op.source_digest()
            (stack / "terraform.tfvars").write_text("modified")
            self.assertNotEqual(before, op.source_digest())
            before = op.source_digest()
            (stack / "extra_override.tf.json").write_text("{}")
            self.assertNotEqual(before, op.source_digest())

    def test_plan_never_invokes_apply_and_binds_identity(self):
        self.apply_mocks()
        def tf(*args):
            self.assertNotIn("apply", args)
            if args[0] == "plan":
                Path(next(a.split("=", 1)[1] for a in args if a.startswith("-out="))).write_bytes(b"saved")
                return "synthetic log"
            if args[0] == "show":
                return json.dumps({"variables": {"allowed_account_ids": {"value": [self.args.expected_account_id]},
                                                  "aws_region": {"value": "ap-northeast-2"}},
                                   "resource_changes": [{"change": {"actions": ["create"]}}]})
            return ""
        self.operator.tf = tf
        with patch.object(op, "source_digest", return_value="source"):
            self.operator.plan()
        records = list(self.root.glob("review-*/review.json"))
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(records[0].read_text())["principal"], "test-role")
        self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)

    def test_missing_outputs_give_recovery_instructions(self):
        for outputs in ({}, {"cluster_name": {"value": "test-cluster"}}):
            with patch.object(self.operator, "tf", return_value=json.dumps(outputs)), \
                 self.assertRaisesRegex(op.SafeError, "부분 적용.*콘솔"):
                self.operator.cleanup_gate()

    def test_concurrent_apply_marker_reports_attempt_and_does_not_apply(self):
        self.review()
        self.apply_mocks()
        original_open = Path.open
        def race_open(path, *args, **kwargs):
            if path.name == "attempted":
                raise FileExistsError("synthetic concurrent writer")
            return original_open(path, *args, **kwargs)
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(Path, "open", race_open), patch.object(self.operator, "tf") as tf:
            with self.assertRaisesRegex(op.SafeError, "다른 실행"):
                self.operator.apply()
            tf.assert_not_called()

    def test_streamed_output_is_written_before_exit_and_not_printed(self):
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code):
                folder = self.root / f"stream-{exit_code}"
                folder.mkdir()
                log = folder / "apply.log"
                process = Mock()
                reads = []
                def popen(*args, **kwargs):
                    kwargs["stdout"].write(b"synthetic private output\n")
                    kwargs["stdout"].flush()
                    self.assertEqual(log.read_bytes(), b"synthetic private output\n")
                    self.assertEqual(log.stat().st_mode & 0o777, 0o600)
                    reads.append(True)
                    manager = Mock()
                    manager.__enter__ = Mock(return_value=process)
                    manager.__exit__ = Mock(return_value=False)
                    return manager
                process.wait.side_effect = [op.subprocess.TimeoutExpired("synthetic", 30), exit_code]
                output = io.StringIO()
                with patch.object(op.subprocess, "Popen", side_effect=popen), redirect_stdout(output):
                    if exit_code:
                        with self.assertRaises(op.SafeError):
                            self.operator.run_live(["synthetic"], log)
                    else:
                        self.operator.run_live(["synthetic"], log)
                self.assertEqual(reads, [True])
                self.assertIn("진행 중", output.getvalue())
                self.assertNotIn("synthetic private output", output.getvalue())
                self.assertEqual((folder / "apply-error.log").exists(), bool(exit_code))
                if exit_code:
                    self.assertEqual((folder / "apply-error.log").read_bytes(), log.read_bytes())
                    self.assertEqual((folder / "apply-error.log").stat().st_mode & 0o777, 0o600)

    def test_interrupt_waits_without_second_signal(self):
        process = Mock()
        process.wait.side_effect = [KeyboardInterrupt(), 0]
        manager = Mock()
        manager.__enter__ = Mock(return_value=process)
        manager.__exit__ = Mock(return_value=False)
        with patch.object(op.subprocess, "Popen", return_value=manager), redirect_stdout(io.StringIO()):
            self.operator.run_live(["synthetic"], self.root / "apply.log")
        process.send_signal.assert_not_called()
        self.assertEqual(process.wait.call_count, 2)


@unittest.skipUnless(shutil.which("aws"), "aws CLI 없음")
class RealCliInputTests(unittest.TestCase):
    """가짜 aws만으로는 CLI가 입력을 실제로 받아들이는지 알 수 없다(11/23 file:///dev/stdin 사고).
    요청은 닫힌 로컬 주소로 보내 실패시키고, 입력 해석 단계(ParamValidation)를 통과하는지만 본다."""

    def test_cli_input_json_temp_file_is_accepted_by_real_cli(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(op, "ARTIFACTS", Path(tmp)):
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp, "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE",
                   "AWS_SECRET_ACCESS_KEY": "example", "AWS_MAX_ATTEMPTS": "1", "AWS_PAGER": ""}
            with op.cli_input_json({"SecretId": "arn:aws:secretsmanager:ap-northeast-2:000000000000:secret:x"}) as extra:
                result = subprocess.run(["aws", "secretsmanager", "describe-secret", *extra, "--region", "ap-northeast-2",
                                         "--endpoint-url", "http://127.0.0.1:9", "--cli-connect-timeout", "1"],
                                        env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)  # 닫힌 주소라 실패가 정상
        self.assertNotIn("ParamValidation", result.stderr)
        self.assertNotIn("Invalid JSON", result.stderr)
        self.assertIn("127.0.0.1", result.stderr)  # 입력 해석을 지나 실제 요청 단계까지 갔다


if __name__ == "__main__":
    unittest.main()
