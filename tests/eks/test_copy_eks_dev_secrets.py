"""EC2 dev → EKS dev secret copy (#63): no AWS, cluster or real secret access."""
import base64
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("copy_eks_dev_secrets", ROOT / "scripts/ec2/copy_eks_dev_secrets.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Synthetic values only, built at runtime (no secret-like literals for Gitleaks). Each is unique so a leak is detectable.
LEAK_ACCOUNT = "4" * 12  # stands in for a real account ID inside AWS error text


def v(name):
    return "synthetic-" + name


SHARED = {"JWT_PUBLIC_KEY": v("public-key-0001"), "INTERNAL_SERVICE_TOKEN": v("internal-0002")}


def b64(value):
    return base64.b64encode(value.encode()).decode()


def ec2_secrets():
    secrets = {
        "ureka-auth-secrets": {"DB_PASSWORD": v("auth-db-0003"), "JWT_PRIVATE_KEY": v("private-0004"),
                               "EMAIL_CODE_SECRET": v("email-0005"), **SHARED},
        "ureka-content-secrets": {"DB_PASSWORD": v("content-db-0006"), **SHARED},
        "ureka-chat-secrets": {"DB_PASSWORD": v("chat-db-0007"), **SHARED},
        "ureka-ops-secrets": {"DB_PASSWORD": v("ops-db-0008"), "JWT_PUBLIC_KEY": SHARED["JWT_PUBLIC_KEY"]},
        "ureka-recommend-secrets": {"INTERNAL_SERVICE_TOKEN": SHARED["INTERNAL_SERVICE_TOKEN"]},
        "ureka-recommend-db": {"DB_USERNAME": "content_db_recommend", "DB_PASSWORD": v("rec-db-0009")},
        "ureka-ingest-db": {"DB_USERNAME": "content_db_ingest", "DB_PASSWORD": v("ingest-db-0010")},
        "ureka-chat-ai": {"AI_MODE": "gemini", "AI_API_KEY": v("ai-key-0011")},
    }
    return secrets


def all_values(secrets):
    return {x for data in secrets.values() for x in data.values() if x.startswith("synthetic-")}


class FakeRun:
    ARN_ERROR = "An error occurred (AccessDeniedException) ... arn:" + "aws:secretsmanager:ap-northeast-2:" + LEAK_ACCOUNT + ":secret:x"

    def __init__(self, secrets, remote=None, kubectl_error=None, describe_error=None, fail_write=None):
        self.fail_write = fail_write
        self.secrets = secrets
        self.remote = remote or {}
        self.kubectl_error = kubectl_error
        self.describe_error = describe_error
        self.calls = []
        self.written = {}

    def __call__(self, command, check=True):
        self.calls.append(list(command))
        if command[0] == "kubectl":
            name = command[command.index("secret") + 1]
            if self.kubectl_error:
                return SimpleNamespace(returncode=1, stdout="", stderr=self.kubectl_error)
            if name not in self.secrets:
                return SimpleNamespace(returncode=1, stdout="", stderr=f'Error from server (NotFound): secrets "{name}" not found')
            data = {k: b64(v) for k, v in self.secrets[name].items()}
            return SimpleNamespace(returncode=0, stdout=json.dumps({"data": data}), stderr="")
        sub = command[2]
        name = command[command.index("--secret-id" if "--secret-id" in command else "--name") + 1]
        if sub == "describe-secret":
            if self.describe_error:
                return SimpleNamespace(returncode=255, stdout="", stderr=self.describe_error)
            if name not in self.remote:
                return SimpleNamespace(returncode=254, stdout="", stderr="An error occurred (ResourceNotFoundException)")
            return SimpleNamespace(returncode=0, stdout=json.dumps(self.remote[name]), stderr="")
        if sub in ("create-secret", "put-secret-value"):
            if name == self.fail_write:
                stderr = "An error occurred (InternalServiceError) " + self.ARN_ERROR
                if check:  # same contract as module.Runner
                    raise module.SafeError(f"aws 실행 실패{module.exception_name(stderr)}(원문 미출력).")
                return SimpleNamespace(returncode=255, stdout="", stderr=stderr)
            path = command[command.index("--secret-string") + 1]
            assert path.startswith("file://")
            self.written[name] = (sub, json.loads(Path(path[7:]).read_text()))
            return SimpleNamespace(returncode=0, stdout=json.dumps({"ARN": "arn:" + "aws:secretsmanager:x:" + LEAK_ACCOUNT + ":secret:y"}), stderr="")
        raise AssertionError(command)

    def writes(self):
        return [c for c in self.calls if c[0] == "aws" and c[2] in ("create-secret", "put-secret-value")]


class CopyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.secrets = ec2_secrets()

    def tearDown(self):
        self.tmp.cleanup()

    def run_copy(self, fake, action="copy", update=False):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                module.copy(fake, "ap-northeast-2", action, update, self.tmp.name)
                error = None
            except module.SafeError as e:
                error = str(e)
        printed = out.getvalue() + err.getvalue() + (error or "")
        for value in all_values(self.secrets):
            self.assertNotIn(value, printed)
        self.assertNotIn(LEAK_ACCOUNT, printed)
        # Secret values never reach any command line.
        for call in fake.calls:
            for value in all_values(self.secrets):
                self.assertNotIn(value, " ".join(call))
        self.assertEqual(list(Path(self.tmp.name).iterdir()), [], "temporary value files must be removed")
        return error

    def test_bundles_match_chart_values(self):
        out = subprocess.run(["yq", "-o=json", ".bundles", str(ROOT / "charts/ureka-eks-secrets/values.yaml")],
                             check=True, capture_output=True, text=True).stdout
        self.assertEqual(json.loads(out), module.BUNDLES)

    def test_creates_both_bundles_with_exact_values(self):
        fake = FakeRun(self.secrets)
        self.assertIsNone(self.run_copy(fake))
        sub, app = fake.written["ureka/eks/dev/app"]
        self.assertEqual(sub, "create-secret")
        self.assertEqual(app["AUTH_DB_PASSWORD"], v("auth-db-0003"))
        self.assertEqual(app["JWT_PUBLIC_KEY"], SHARED["JWT_PUBLIC_KEY"])
        self.assertEqual(app["INGEST_DB_USERNAME"], "content_db_ingest")
        self.assertEqual(len(app), 12)
        self.assertEqual(fake.written["ureka/eks/dev/chat-ai"][1],
                         {"AI_MODE": "gemini", "AI_API_KEY": v("ai-key-0011")})
        # Only these two names, only under the dev prefix; EC2 side is only read.
        self.assertEqual(set(fake.written), {"ureka/eks/dev/app", "ureka/eks/dev/chat-ai"})
        for call in fake.calls:
            if call[0] == "kubectl":
                self.assertIn("get", call)
                self.assertNotIn("create", call)
                self.assertNotIn("apply", call)

    def test_mismatched_shared_value_writes_nothing(self):
        self.secrets["ureka-chat-secrets"]["JWT_PUBLIC_KEY"] = v("other-public-0012")
        fake = FakeRun(self.secrets)
        self.assertIn("JWT_PUBLIC_KEY", self.run_copy(fake))
        self.assertFalse([c for c in fake.calls if c[0] == "aws"])

    def test_missing_required_secret_writes_nothing(self):
        del self.secrets["ureka-ops-secrets"]
        fake = FakeRun(self.secrets)
        self.assertIn("ureka-ops-secrets", self.run_copy(fake))
        self.assertFalse([c for c in fake.calls if c[0] == "aws"])

    def test_unexpected_username_rejected(self):
        self.secrets["ureka-recommend-db"]["DB_USERNAME"] = "postgres"
        fake = FakeRun(self.secrets)
        self.assertIsNotNone(self.run_copy(fake))
        self.assertFalse(fake.writes())

    def test_missing_chat_ai_writes_nothing(self):
        # EKS dev always wires chat-ai, so a copy without it would leave an ExternalSecret that can never be Ready.
        del self.secrets["ureka-chat-ai"]
        fake = FakeRun(self.secrets)
        self.assertIn("ureka-chat-ai", self.run_copy(fake))
        self.assertFalse([c for c in fake.calls if c[0] == "aws"])

    def test_second_write_failure_then_resume_with_update_existing(self):
        fake = FakeRun(self.secrets, fail_write="ureka/eks/dev/chat-ai")
        error = self.run_copy(fake)
        self.assertIn("이미 쓴 묶음: ureka/eks/dev/app", error)
        self.assertIn("쓰지 못한 묶음: ureka/eks/dev/chat-ai", error)
        self.assertEqual(set(fake.written), {"ureka/eks/dev/app"})
        # Plain retry refuses because app now exists; nothing is written.
        retry = FakeRun(self.secrets, remote={"ureka/eks/dev/app": {"Name": "x"}})
        self.assertIn("이미 있는", self.run_copy(retry))
        self.assertFalse(retry.writes())
        # Documented recovery: same source, --update-existing adds an app version and creates chat-ai.
        resume = FakeRun(self.secrets, remote={"ureka/eks/dev/app": {"Name": "x"}})
        self.assertIsNone(self.run_copy(resume, update=True))
        self.assertEqual(resume.written["ureka/eks/dev/app"][0], "put-secret-value")
        self.assertEqual(resume.written["ureka/eks/dev/chat-ai"][0], "create-secret")
        self.assertEqual(resume.written["ureka/eks/dev/app"][1], fake.written["ureka/eks/dev/app"][1])

    def test_existing_remote_is_not_overwritten(self):
        fake = FakeRun(self.secrets, remote={"ureka/eks/dev/chat-ai": {"Name": "x"}})
        self.assertIn("이미 있는", self.run_copy(fake))
        self.assertFalse(fake.writes(), "no partial write when any target exists")

    def test_update_existing_puts_new_version(self):
        fake = FakeRun(self.secrets, remote={"ureka/eks/dev/app": {"Name": "x"}})
        self.assertIsNone(self.run_copy(fake, update=True))
        self.assertEqual(fake.written["ureka/eks/dev/app"][0], "put-secret-value")
        self.assertEqual(fake.written["ureka/eks/dev/chat-ai"][0], "create-secret")

    def test_scheduled_deletion_stops(self):
        fake = FakeRun(self.secrets, remote={"ureka/eks/dev/app": {"DeletedDate": "2026-11-22"}})
        self.assertIn("삭제 예약", self.run_copy(fake, update=True))
        self.assertFalse(fake.writes())

    def test_check_mode_never_writes(self):
        fake = FakeRun(self.secrets, remote={"ureka/eks/dev/app": {"Name": "x"}})
        self.assertIsNone(self.run_copy(fake, action="check"))
        self.assertFalse(fake.writes())

    def test_kubectl_forbidden_is_not_treated_as_missing(self):
        fake = FakeRun(self.secrets, kubectl_error="Error from server (Forbidden): secrets is forbidden")
        self.assertIn("Forbidden", self.run_copy(fake))
        self.assertFalse([c for c in fake.calls if c[0] == "aws"])

    def test_access_denied_hides_arn(self):
        fake = FakeRun(self.secrets, describe_error=FakeRun.ARN_ERROR)
        error = self.run_copy(fake)
        self.assertIn("AccessDeniedException", error)
        self.assertFalse(fake.writes())

    def test_region_marker_required(self):
        with self.assertRaises(module.SafeError):
            module.region_from(Path(self.tmp.name) / "missing.env")
        marker = Path(self.tmp.name) / "registry.env"
        marker.write_text("ECR_REGISTRY=x\nAWS_REGION=ap-northeast-2\n")
        self.assertEqual(module.region_from(marker), "ap-northeast-2")
        marker.unlink()


if __name__ == "__main__":
    unittest.main()
