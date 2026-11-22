"""prod 비밀 시드(#63 후속): AWS 없이 가짜 aws로 돈다. openssl은 실제로 부른다(키 쌍 형식 확인)."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("seed_prod_secrets", ROOT / "scripts/eks/seed_prod_secrets.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ACCOUNT = "000000000000"
LEAK_ACCOUNT = "4" * 12  # 실제 계정 ID 자리(오류 원문 속 ARN)
ARN_ERROR = f"arn:aws:secretsmanager:ap-northeast-2:{LEAK_ACCOUNT}:secret:ureka/eks/prod/app-AbCdEf"


class FakeRun:
    """aws만 흉내 낸다. openssl은 진짜로 실행한다."""

    def __init__(self, remote=None, describe_error=None, create_error=None, created_anyway=False, account=ACCOUNT,
                 password=None):
        self.remote = remote
        self.describe_error = describe_error
        self.create_error = create_error
        self.created_anyway = created_anyway
        self.account = account
        self.password = password
        self.calls = []
        self.stdins = []
        self.created = None
        self.counter = 0

    def __call__(self, command, check=True, stdin=None):
        self.calls.append(list(command))
        self.stdins.append(stdin)
        if command[0] == "openssl":
            result = subprocess.run(command, capture_output=True, text=True)
            return self.done(result.returncode, result.stdout, result.stderr, check, command)
        if command[1:3] == ["sts", "get-caller-identity"]:
            return self.done(0, json.dumps({"Account": self.account, "Arn": ARN_ERROR}), "", check, command)
        sub = command[2]
        if sub == "describe-secret":
            if self.describe_error:
                return self.done(255, "", self.describe_error + " " + ARN_ERROR, check, command)
            if self.remote is None:
                return self.done(254, "", f"An error occurred (ResourceNotFoundException) {ARN_ERROR}", check, command)
            return self.done(0, json.dumps(self.remote), "", check, command)
        if sub == "get-random-password":
            self.counter += 1
            value = self.password or ("Pw%02d" % self.counter + "a1B" * 20)[:64]
            return self.done(0, json.dumps({"RandomPassword": value}), "", check, command)
        if sub == "create-secret":
            assert command[command.index("--secret-string") + 1] == "file:///dev/stdin"
            if self.create_error:
                if self.created_anyway:
                    self.remote = {"Name": "ureka/eks/prod/app"}
                return self.done(255, "", f"An error occurred ({self.create_error}) {ARN_ERROR}", check, command)
            self.created = json.loads(stdin)
            self.remote = {"Name": "ureka/eks/prod/app"}
            return self.done(0, json.dumps({"ARN": ARN_ERROR}), "", check, command)
        raise AssertionError(command)

    @staticmethod
    def done(code, out, err, check, command):
        if check and code:
            raise module.SafeError(f"{command[0]} 실패{module.exception_name(err)}(원문 미출력).")
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)

    def subs(self):
        return [c[2] for c in self.calls if c[0] == "aws"]


class SeedTests(unittest.TestCase):
    def run_main(self, fake, argv=("create", "--profile", "p", "--confirm-env", "prod"), account=ACCOUNT):
        out, err = io.StringIO(), io.StringIO()
        seen_dirs = []
        real_mkdtemp = tempfile.mkdtemp

        def mkdtemp(**kwargs):
            path = real_mkdtemp(**kwargs)
            seen_dirs.append(path)
            return path

        with patch.dict(os.environ, {"UREKA_EXPECTED_ACCOUNT_ID": account}), \
                patch.object(module.tempfile, "mkdtemp", side_effect=mkdtemp), \
                redirect_stdout(out), redirect_stderr(err):
            code = module.main(list(argv), runner=fake)
        printed = out.getvalue() + err.getvalue()
        self.assertNotIn(LEAK_ACCOUNT, printed)
        self.assertNotIn(ACCOUNT, printed)
        for path in seen_dirs:
            self.assertFalse(os.path.exists(path), "임시 폴더가 남았습니다")
        if fake.created:
            for value in fake.created.values():
                if value not in module.USERNAMES.values():
                    self.assertNotIn(value, printed)
                    for call in fake.calls:  # 값은 어떤 명령 인자에도 없다
                        self.assertNotIn(value, " ".join(call))
        return code, printed

    def test_properties_match_chart_app_bundle(self):
        out = subprocess.run(["yq", "-o=json", ".bundles.app", str(ROOT / "charts/ureka-eks-secrets/values.yaml")],
                             check=True, capture_output=True, text=True).stdout
        chart = {prop for keys in json.loads(out).values() for prop in keys.values()}
        self.assertEqual(chart, set(module.PROPERTIES))

    def test_prod_usernames_follow_bootstrap_suffix(self):
        self.assertEqual(module.USERNAMES, {"RECOMMEND_DB_USERNAME": "content_db_prod_recommend",
                                            "INGEST_DB_USERNAME": "content_db_prod_ingest"})

    @unittest.skipUnless(shutil.which("openssl"), "openssl 필요")
    def test_create_writes_one_bundle_through_stdin(self):
        fake = FakeRun()
        code, printed = self.run_main(fake)
        self.assertEqual(code, 0, printed)
        self.assertEqual(set(fake.created), set(module.PROPERTIES))
        randoms = [fake.created[p] for p in module.RANDOM_PROPERTIES]
        self.assertEqual(len(set(randoms)), 8)
        self.assertTrue(all(len(v) == 64 for v in randoms))
        self.assertTrue(fake.created["JWT_PRIVATE_KEY"].startswith("-----BEGIN PRIVATE KEY-----"))
        # 공개키는 개인키에서 나온 것이어야 한다.
        with tempfile.TemporaryDirectory() as d:
            key = Path(d) / "k.pem"
            key.write_text(fake.created["JWT_PRIVATE_KEY"])
            derived = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout"], capture_output=True, text=True,
                                     check=True).stdout
        self.assertEqual(derived, fake.created["JWT_PUBLIC_KEY"])
        self.assertEqual(fake.subs().count("get-random-password"), 8)
        self.assertEqual(fake.subs().count("create-secret"), 1)
        create = next(c for c in fake.calls if c[0] == "aws" and c[2] == "create-secret")
        self.assertEqual(create[create.index("--name") + 1], "ureka/eks/prod/app")
        self.assertNotIn("ses-smtp", " ".join(create))

    def test_existing_secret_stops_before_generating(self):
        fake = FakeRun(remote={"Name": "ureka/eks/prod/app"})
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("이미 있습니다", printed)
        self.assertNotIn("get-random-password", fake.subs())
        self.assertNotIn("create-secret", fake.subs())
        self.assertFalse(any(c[0] == "openssl" for c in fake.calls))

    def test_scheduled_deletion_stops(self):
        fake = FakeRun(remote={"Name": "ureka/eks/prod/app", "DeletedDate": "2026-11-23T00:00:00Z"})
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("삭제 예약", printed)
        self.assertNotIn("create-secret", fake.subs())

    def test_describe_error_is_not_absent(self):
        fake = FakeRun(describe_error="An error occurred (AccessDeniedException)")
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("AccessDeniedException", printed)
        self.assertNotIn("create-secret", fake.subs())

    def test_wrong_account_stops_first(self):
        fake = FakeRun(account="1" * 12)
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("승인된 AWS 계정이 아닙니다", printed)
        self.assertEqual(fake.subs(), ["get-caller-identity"])

    def test_check_changes_nothing(self):
        fake = FakeRun()
        code, printed = self.run_main(fake, argv=("check", "--profile", "p"))
        self.assertEqual(code, 0, printed)
        self.assertEqual(fake.subs(), ["get-caller-identity", "describe-secret"])

    def test_create_requires_confirm_env(self):
        for argv in (("create", "--profile", "p"), ("create", "--profile", "p", "--confirm-env", "dev")):
            fake = FakeRun()
            code, printed = self.run_main(fake, argv=argv)
            self.assertEqual(code, 1)
            self.assertIn("--confirm-env prod", printed)
            self.assertEqual(fake.calls, [])

    def test_account_env_required(self):
        fake = FakeRun()
        code, printed = self.run_main(fake, account="12345")
        self.assertEqual(code, 1)
        self.assertIn("UREKA_EXPECTED_ACCOUNT_ID", printed)
        self.assertEqual(fake.calls, [])

    def test_bad_random_password_format_stops(self):
        fake = FakeRun(password="short")
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("형식", printed)
        self.assertNotIn("create-secret", fake.subs())

    @unittest.skipUnless(shutil.which("openssl"), "openssl 필요")
    def test_create_failure_absent_says_retry(self):
        fake = FakeRun(create_error="InternalServiceError")
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("만들어지지 않았습니다", printed)
        self.assertIn("InternalServiceError", printed)

    @unittest.skipUnless(shutil.which("openssl"), "openssl 필요")
    def test_create_failure_but_present_points_to_recovery(self):
        fake = FakeRun(create_error="InternalServiceError", created_anyway=True)
        code, printed = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertIn("prod 시드 실패 복구", printed)
        # 값을 담은 표준 입력은 create-secret 한 번에만 갔다.
        sent = [s for s in fake.stdins if s]
        self.assertEqual(len(sent), 1)
        for value in json.loads(sent[0]).values():
            if value not in module.USERNAMES.values():
                self.assertNotIn(value, printed)


if __name__ == "__main__":
    unittest.main()
