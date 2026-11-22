"""prod DB bootstrap 도구(#63 후속): AWS·클러스터 없이 가짜 kubectl·aws·terraform으로 돈다."""
from contextlib import redirect_stderr, redirect_stdout
import base64
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
scripts = ROOT / "scripts/eks"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("bootstrap_prod_db", scripts / "bootstrap_prod_db.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ACCOUNT = "000000000000"
LEAK = "4" * 12  # 실제 계정 ID 자리(ARN 속)
ARN = f"arn:aws:secretsmanager:ap-northeast-2:{LEAK}:secret:rds!db-0123abcd-4567"
HOST = "ureka-data.abcdefghijkl.ap-northeast-2.rds.amazonaws.com"
MASTER_PW = "master-password-marker-0001"


def bundle(**over):
    values = {
        "AUTH_DB_PASSWORD": "A" * 63 + "1", "CONTENT_DB_PASSWORD": "B" * 63 + "2", "CHAT_DB_PASSWORD": "C" * 63 + "3",
        "OPS_DB_PASSWORD": "D" * 63 + "4", "RECOMMEND_DB_PASSWORD": "E" * 63 + "5", "INGEST_DB_PASSWORD": "F" * 63 + "6",
        "RECOMMEND_DB_USERNAME": "content_db_prod_recommend", "INGEST_DB_USERNAME": "content_db_prod_ingest",
        "EMAIL_CODE_SECRET": "G" * 64, "INTERNAL_SERVICE_TOKEN": "H" * 64,
        "JWT_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----x", "JWT_PUBLIC_KEY": "-----BEGIN PUBLIC KEY-----y",
    }
    values.update(over)
    return values


class FakeCluster:
    def __init__(self, app=None, job_result="ok", leftovers=(), stuck=(), namespace_labels=None, history=False):
        self.app = app or bundle()
        self.history = history
        self.job_result = job_result
        self.objects = {k: {} for k in leftovers}
        self.stuck = set(stuck)  # 지워지지 않는 자원(kind/name)
        self.labels = {"pod-security.kubernetes.io/enforce": "restricted"} if namespace_labels is None else namespace_labels
        self.calls, self.stdins, self.created = [], [], []

    def __call__(self, command, stdin=None, check=True):
        self.calls.append(list(command))
        self.stdins.append(stdin)
        code, out, err = self.handle(command, stdin)
        if check and code:
            raise module.SafeError(f"{command[0]} 실패")
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)

    def handle(self, c, stdin):
        if c[0] == "terraform":
            return 0, json.dumps({"master_secret_arn": {"value": ARN}, "endpoint": {"value": HOST},
                                  "security_group_id": {"value": "sg-0"}}), ""
        if c[0] == "aws" and c[1] == "configure":
            return (0, "enabled\n", "") if self.history else (1, "", "")
        if c[0] == "aws":
            if "--cli-input-json" in c:
                assert json.loads(stdin) == {"SecretId": ARN}
                return 0, json.dumps({"SecretString": json.dumps({"username": "ureka_master", "password": MASTER_PW}),
                                      "ARN": ARN}), ""
            assert c[c.index("--secret-id") + 1] == "ureka/eks/prod/app"
            return 0, json.dumps({"SecretString": json.dumps(self.app), "ARN": ARN}), ""
        assert c[0] == "kubectl" and c[1:3] == ["--context", "ureka-eks"] and c[3:5] == ["-n", "prod"], c
        verb, rest = c[6], c[7:]
        if verb == "get" and rest[0] == "namespace":
            return 0, json.dumps({"metadata": {"labels": self.labels}}), ""
        if verb == "create":
            if "kind: Job" in stdin:
                key, obj = f"job/{module.JOB}", stdin
            else:
                obj = json.loads(stdin)
                key = f"{obj['kind'].lower()}/{obj['metadata']['name']}"
            if key in self.objects:
                return 1, "", "Error from server (AlreadyExists)"
            self.objects[key] = obj
            self.created.append(key)
            return 0, f"{key} created", ""
        if verb == "get" and rest[0] == "job" and "json" in rest:
            status = {"ok": {"succeeded": 1}, "failed": {"failed": 1}, "timeout": {}}[self.job_result]
            return 0, json.dumps({"status": status}), ""
        if verb == "get" and rest[0] == "pod":
            return 0, "", ""
        if verb == "get":
            key = f"{rest[0]}/{rest[1]}"
            if key in self.objects:
                return 0, key, ""
            return 1, "", f'Error from server (NotFound): {rest[0]} "{rest[1]}" not found'
        if verb == "delete":
            key = f"{rest[0]}/{rest[1]}"
            if key not in self.stuck:
                self.objects.pop(key, None)
            return 0, "", ""
        if verb == "wait":
            return 0, "", ""
        if verb == "logs":
            return 0, ("db-bootstrap 완료 (_prod)\ncheck environment suffix _prod, content db content_db_prod\n"
                       "psql:/bootstrap/db-bootstrap.sql:9: ERROR: x LINE 1: ALTER ROLE a PASSWORD 'SCRAM-SHA-256$4096:abc$def:ghi'\n"
                       "noise line\n"), ""
        raise AssertionError(c)


class BootstrapTests(unittest.TestCase):
    def operator(self, fake, action="apply", confirm="prod"):
        op = module.ProdDbBootstrap.__new__(module.ProdDbBootstrap)
        op.args = SimpleNamespace(action=action, confirm_env=confirm, profile="p", cluster_name="ureka-eks",
                                  context="ureka-eks", expected_account_id=ACCOUNT, max_wait=1, poll=0)
        op.env = {}
        op.identity = Mock(return_value={"Account": ACCOUNT})
        op.aws = Mock(return_value={"cluster": {"arn": f"arn:aws:eks:ap-northeast-2:{ACCOUNT}:cluster/ureka-eks",
                                                "status": "ACTIVE", "endpoint": "https://example.invalid"}})
        op.run = Mock(return_value='{"current-context": "ureka-eks", "contexts": [{"context": {"cluster": "c"}}],'
                                   ' "clusters": [{"name": "c", "cluster": {"server": "https://example.invalid"}}]}')
        op.quiet = fake
        return op

    def execute(self, fake, **kw):
        op = self.operator(fake, **kw)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), patch.object(module.time, "sleep"):
            try:
                rc, error = op.execute(), None
            except module.SafeError as e:
                rc, error = None, str(e)
        printed = out.getvalue() + err.getvalue() + (error or "")
        secrets = [MASTER_PW, LEAK] + [v for k, v in fake.app.items() if "PASSWORD" in k and v]
        for value in secrets:
            self.assertNotIn(value, printed)
            for call in fake.calls:
                self.assertNotIn(value, " ".join(call), "값·ARN이 명령 인자에 실렸습니다")
        self.assertNotIn("SCRAM-SHA-256$4096", printed)
        return rc, error, printed

    def created_secret(self, fake, name):
        data = fake.objects_snapshot[f"secret/{name}"]["data"]
        return {k: base64.b64decode(v).decode() for k, v in data.items()}

    def test_apply_creates_runs_and_cleans_up(self):
        fake = FakeCluster()
        snapshot = {}
        original = fake.handle

        def keep(c, stdin):  # 지워지기 전 내용을 남긴다
            result = original(c, stdin)
            if c[0] == "kubectl" and c[6] == "create":
                snapshot.update(fake.objects)
            return result
        fake.handle = keep
        rc, error, printed = self.execute(fake)
        self.assertEqual((rc, error), (0, None), printed)
        # 해시 Secret → ConfigMap → 마스터 Secret → Job 순서
        self.assertEqual(fake.created, [f"secret/{module.ACCOUNTS_SECRET}", f"configmap/{module.CONFIGMAP}",
                                        f"secret/{module.MASTER_SECRET}", f"job/{module.JOB}"])
        # 모두 지워졌다
        self.assertEqual(fake.objects, {})
        self.assertIn("정리 확인", printed)
        # 해시는 각 비밀번호의 SCRAM verifier다(원문 없음)
        hashes = {k: base64.b64decode(v).decode() for k, v in snapshot[f"secret/{module.ACCOUNTS_SECRET}"]["data"].items()}
        self.assertEqual(set(hashes), set(module.HASHES.values()))
        for prop, var in module.HASHES.items():
            salt = base64.b64decode(hashes[var].split(":")[1].split("$")[0])
            self.assertEqual(hashes[var], module.scram(fake.app[prop], salt))
            self.assertNotIn(fake.app[prop], json.dumps(snapshot[f"secret/{module.ACCOUNTS_SECRET}"]))
        master = {k: base64.b64decode(v).decode() for k, v in snapshot[f"secret/{module.MASTER_SECRET}"]["data"].items()}
        self.assertEqual(master, {"PGUSER": "ureka_master", "PGPASSWORD": MASTER_PW})
        job = snapshot[f"job/{module.JOB}"]
        self.assertIn(f"value: {HOST}\n", job)
        self.assertNotIn("RDS_ENDPOINT", job)
        cm = snapshot[f"configmap/{module.CONFIGMAP}"]["data"]
        self.assertEqual(cm["db-bootstrap.sql"], module.SQL_FILE.read_text())
        # 로그 요약: 확인·오류 줄만, 해시는 가림
        self.assertIn("check environment suffix _prod", printed)
        self.assertIn("SCRAM-SHA-256$<생략>", printed)
        self.assertNotIn("noise line", printed)

    def test_job_failure_still_cleans_up(self):
        fake = FakeCluster(job_result="failed")
        rc, error, printed = self.execute(fake)
        self.assertEqual(rc, 1)
        self.assertEqual(fake.objects, {})
        self.assertIn("실패", printed)

    def test_timeout_still_cleans_up(self):
        fake = FakeCluster(job_result="timeout")
        rc, _, printed = self.execute(fake)
        self.assertEqual(rc, 1)
        self.assertEqual(fake.objects, {})

    def test_cleanup_failure_is_loud(self):
        fake = FakeCluster(stuck=[f"secret/{module.MASTER_SECRET}"])
        rc, _, printed = self.execute(fake)
        self.assertEqual(rc, 3)
        self.assertIn(f"secret/{module.MASTER_SECRET}", printed)
        self.assertIn("경고", printed)

    def test_leftovers_are_removed_before_reading_master(self):
        fake = FakeCluster(leftovers=[f"secret/{module.MASTER_SECRET}", f"job/{module.JOB}"])
        rc, _, _ = self.execute(fake)
        self.assertEqual(rc, 0)

    def test_undeletable_leftover_stops_before_master(self):
        fake = FakeCluster(leftovers=[f"job/{module.JOB}"], stuck=[f"job/{module.JOB}"])
        rc, error, _ = self.execute(fake)
        self.assertIsNone(rc)
        self.assertIn("마스터 비밀을 읽지 않고", error)
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))
        self.assertEqual(fake.created, [])

    def test_check_reads_no_master_and_creates_nothing(self):
        fake = FakeCluster()
        rc, error, printed = self.execute(fake, action="check", confirm=None)
        self.assertEqual((rc, error), (0, None))
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))
        self.assertFalse(any(c[0] == "kubectl" and c[6] in ("create", "delete") for c in fake.calls))
        self.assertIn("변경 없음", printed)

    def test_apply_requires_confirm_env(self):
        fake = FakeCluster()
        rc, error, _ = self.execute(fake, confirm="dev")
        self.assertIn("--confirm-env prod", error)
        self.assertEqual(fake.calls, [])

    def test_dev_usernames_stop_before_master(self):
        fake = FakeCluster(app=bundle(RECOMMEND_DB_USERNAME="content_db_recommend"))
        rc, error, _ = self.execute(fake)
        self.assertIn("prod 계정 이름", error)
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))
        self.assertEqual(fake.created, [])

    def test_missing_or_shared_password_stops(self):
        for app in (bundle(OPS_DB_PASSWORD=""), bundle(OPS_DB_PASSWORD="A" * 63 + "1")):
            fake = FakeCluster(app=app)
            rc, error, _ = self.execute(fake)
            self.assertIsNotNone(error)
            self.assertEqual(fake.created, [])

    def test_cli_history_enabled_stops_before_reading(self):
        fake = FakeCluster(history=True)
        rc, error, _ = self.execute(fake)
        self.assertIn("cli_history", error)
        self.assertFalse(any(c[:3] == ["aws", "secretsmanager", "get-secret-value"] for c in fake.calls))

    def test_namespace_must_be_restricted(self):
        fake = FakeCluster(namespace_labels={})
        rc, error, _ = self.execute(fake)
        self.assertIn("restricted", error)

    def test_scram_matches_known_postgres_format(self):
        value = module.scram("pw", b"\x00" * 16)
        self.assertRegex(value, r"^SCRAM-SHA-256\$4096:[A-Za-z0-9+/=]{24}\$[A-Za-z0-9+/=]{44}:[A-Za-z0-9+/=]{44}$")
        self.assertEqual(value, module.scram("pw", b"\x00" * 16))
        self.assertNotEqual(value, module.scram("pw2", b"\x00" * 16))


class JobManifestTests(unittest.TestCase):
    def job(self):
        out = subprocess.run(["yq", "-o=json", ".", str(module.JOB_FILE)], check=True, capture_output=True, text=True).stdout
        return json.loads(out)

    def test_job_is_prod_and_restricted(self):
        job = self.job()
        self.assertEqual(job["metadata"]["namespace"], "prod")
        self.assertEqual(job["metadata"]["name"], module.JOB)
        pod = job["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
        for key in ("hostNetwork", "hostPID", "hostIPC", "serviceAccountName"):
            self.assertNotIn(key, pod)
        (container,) = pod["containers"]
        sc = container["securityContext"]
        self.assertFalse(sc["allowPrivilegeEscalation"])
        self.assertEqual(sc["capabilities"]["drop"], ["ALL"])
        self.assertTrue(sc["readOnlyRootFilesystem"])
        self.assertEqual(pod["volumes"], [{"name": "bootstrap", "configMap": {"name": module.CONFIGMAP}}])
        self.assertEqual(job["spec"]["backoffLimit"], 0)

    def test_job_uses_prod_suffix_and_temporary_secrets_only(self):
        (container,) = self.job()["spec"]["template"]["spec"]["containers"]
        env = {e["name"]: e for e in container["env"]}
        self.assertEqual(env["DB_SUFFIX"]["value"], "_prod")
        self.assertEqual(env["PGHOST"]["value"], "RDS_ENDPOINT")
        self.assertEqual({env[k]["valueFrom"]["secretKeyRef"]["name"] for k in ("PGUSER", "PGPASSWORD")}, {module.MASTER_SECRET})
        self.assertEqual(container["envFrom"], [{"secretRef": {"name": module.ACCOUNTS_SECRET}}])
        self.assertEqual(module.JOB_FILE.read_text().count(module.PLACEHOLDER), 1)

    def test_resources_fit_prod_limitrange(self):
        (container,) = self.job()["spec"]["template"]["spec"]["containers"]
        self.assertEqual(container["resources"]["limits"], {"cpu": "200m", "memory": "128Mi"})  # LimitRange 최대 1코어·1Gi 안

    def test_same_image_as_ec2_bootstrap(self):
        ec2 = subprocess.run(["yq", ".spec.template.spec.containers[0].image",
                              str(ROOT / "environments/ec2/dev/rds-bootstrap/job.yaml")],
                             check=True, capture_output=True, text=True).stdout.strip()
        (container,) = self.job()["spec"]["template"]["spec"]["containers"]
        self.assertEqual(container["image"], ec2)

    def test_no_argo_application_points_at_bootstrap_folder(self):
        hits = subprocess.run(["git", "grep", "-l", "eks/prod/db-bootstrap", "--", "argocd", "environments"],
                              cwd=ROOT, capture_output=True, text=True).stdout.split()
        self.assertEqual(hits, [])

    def test_hash_variables_match_sql(self):
        sql = module.SQL_FILE.read_text()
        for var in module.HASHES.values():
            self.assertRegex(sql, rf"\\getenv [a-z_]+ {var}\n")


if __name__ == "__main__":
    unittest.main()
