"""Safety boundary tests; no AWS/Terraform processes are launched."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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
        for key in ("TF_CLI_ARGS_plan", "TF_VAR_admin_role_arn", "TF_WORKSPACE"):
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

    def test_destroy_requires_explicit_cleanup_confirmation(self):
        self.args.confirm_cleanup = None
        self.operator.tf = lambda *args: json.dumps({"cluster_name": {"value": "test-cluster"}})
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
        with patch.object(op, "source_digest", return_value="source"), patch.object(op.time, "time", return_value=101), \
             patch.object(self.operator, "tf", return_value="synthetic apply log") as tf:
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


if __name__ == "__main__":
    unittest.main()
