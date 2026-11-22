"""Load Balancer Controller registration and public ALB WAF verification; no AWS or cluster access."""
import importlib.util
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

scripts = Path(__file__).resolve().parents[2] / "scripts/eks"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("register_lbc_app", scripts / "register_lbc_app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ACCOUNT = "000000000000"
CLUSTER = {"arn": f"arn:aws:eks:ap-northeast-2:{ACCOUNT}:cluster/ureka-eks", "status": "ACTIVE",
           "endpoint": "https://example.invalid", "resourcesVpcConfig": {"vpcId": "vpc-1"}}
CONFIG = ('{"current-context": "ureka-eks", "contexts": [{"context": {"cluster": "c"}}],'
          ' "clusters": [{"name": "c", "cluster": {"server": "https://example.invalid"}}]}')


class RegisterTests(unittest.TestCase):
    def operator(self, action="check", confirm=None, aws=None):
        op = module.Register.__new__(module.Register)
        op.args = SimpleNamespace(action=action, cluster_name="ureka-eks", context="ureka-eks",
                                  confirm_cluster=confirm, expected_account_id=ACCOUNT)
        op.env = {}
        op.identity = Mock(return_value={"Account": ACCOUNT})
        op.run = Mock(return_value=CONFIG)
        op.aws = aws or self.aws()
        return op

    def aws(self, acls=("ureka-eks-public",), tags=None, attached="ureka-eks-public"):
        tags = tags if tags is not None else [{"Key": "elbv2.k8s.aws/cluster", "Value": "ureka-eks"},
                                              {"Key": "ingress.k8s.aws/stack", "Value": "ureka-prod"}]
        def call(*args):
            if args[:2] == ("eks", "describe-cluster"):
                return {"cluster": CLUSTER}
            if args[:2] == ("iam", "get-role"):
                return {"Role": {}}
            if args[:2] == ("wafv2", "list-web-acls"):
                return {"WebACLs": [{"Name": n} for n in acls]}
            if args[:2] == ("elbv2", "describe-load-balancers"):
                return {"LoadBalancers": [{"LoadBalancerArn": "alb-1", "VpcId": "vpc-1"}]}
            if args[:2] == ("elbv2", "describe-tags"):
                return {"TagDescriptions": [{"ResourceArn": "alb-1", "Tags": tags}]}
            if args[:2] == ("wafv2", "get-web-acl-for-resource"):
                return {"WebACL": {"Name": attached}} if attached else {}
            raise AssertionError(args)
        return call

    def test_inject_replaces_exactly_the_placeholder(self):
        source = module.APP.read_text()
        out = module.inject_account(source, ACCOUNT)
        self.assertIn(f"arn:aws:iam::{ACCOUNT}:role/ureka-eks-aws-load-balancer-controller", out)
        self.assertNotIn("ACCOUNT_ID_INJECTED_AT_REGISTRATION", out)
        with self.assertRaises(module.SafeError):
            module.inject_account(out, ACCOUNT)
        with self.assertRaises(module.SafeError):
            module.inject_account(source, "12345")

    def test_git_file_has_no_account_id(self):
        self.assertEqual(module.APP.read_text().count(module.PLACEHOLDER), 1)

    def test_missing_waf_stops_before_kubectl(self):
        op = self.operator(aws=self.aws(acls=("other",)))
        with patch.object(module.subprocess, "run") as run:
            with self.assertRaises(module.SafeError):
                op.execute()
            run.assert_not_called()

    def test_apply_requires_confirmation(self):
        op = self.operator(action="apply")
        with patch.object(module.subprocess, "run") as run:
            with self.assertRaises(module.SafeError):
                op.execute()
            run.assert_not_called()

    def test_check_is_server_dry_run_on_stdin(self):
        op = self.operator()
        done = subprocess.CompletedProcess([], 0, "", "")
        with patch.object(module.subprocess, "run", return_value=done) as run:
            op.execute()
        argv = run.call_args.args[0]
        self.assertIn("--dry-run=server", argv)
        self.assertFalse(any(ACCOUNT in part for part in argv))
        self.assertIn(ACCOUNT, run.call_args.kwargs["input"])

    def test_kubectl_failure_output_not_printed(self):
        op = self.operator(action="apply", confirm="ureka-eks")
        failed = subprocess.CompletedProcess([], 1, f"echo {ACCOUNT}", f"error {ACCOUNT}")
        with patch.object(module.subprocess, "run", return_value=failed):
            with self.assertRaises(module.SafeError) as error:
                op.execute()
        self.assertNotIn(ACCOUNT, str(error.exception))

    def test_verify_passes_with_waf_attached(self):
        self.operator(action="verify").execute()

    def test_verify_fails_without_waf(self):
        with self.assertRaises(module.SafeError):
            self.operator(action="verify", aws=self.aws(attached=None)).execute()

    def test_verify_ignores_other_cluster_or_group(self):
        tags = [{"Key": "elbv2.k8s.aws/cluster", "Value": "ureka-eks"},
                {"Key": "ingress.k8s.aws/stack", "Value": "prod/other"}]
        with self.assertRaises(module.SafeError):
            self.operator(action="verify", aws=self.aws(tags=tags)).execute()


if __name__ == "__main__":
    unittest.main()
