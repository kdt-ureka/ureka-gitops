"""prod DB bootstrap 도구(#63 후속): AWS·클러스터 없이 가짜 kubectl·aws·terraform으로 돈다."""
from contextlib import redirect_stderr, redirect_stdout
import base64
import importlib.util
import io
import json
import re
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


RUN_RE = re.compile(r'ureka.io/bootstrap-run: "?([0-9a-f]+)"?')


class FakeCluster:
    """objects: "종류/이름" → 실행 표시 라벨. 여러 실행(operator)이 같은 가짜 클러스터를 같이 쓸 수 있다."""

    def __init__(self, app=None, job_result="ok", leftovers=None, stuck=(), namespace_labels=None, history=False,
                 lease=None, fail_create=None):
        self.app = app or bundle()
        self.history = history
        self.job_result = job_result
        self.objects = dict(leftovers or {})
        self.bodies = {}
        self.stuck = set(stuck)  # 지워지지 않는 자원(kind/name)
        self.fail_create = fail_create  # 이 종류/이름 create는 Forbidden으로 실패
        self.lease = lease  # {"holderIdentity": ..., "acquireTime": ...}
        self.lease_version = 1
        self.labels = {"pod-security.kubernetes.io/enforce": "restricted"} if namespace_labels is None else namespace_labels
        self.calls, self.stdins, self.created, self.deleted = [], [], [], []

    def __call__(self, command, stdin=None, check=True):
        self.calls.append(list(command))
        self.stdins.append(stdin)
        code, out, err = self.handle(command, stdin)
        if check and code:
            raise module.SafeError(f"{command[0]} 실패")
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)

    def lease_json(self):
        return json.dumps({"apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
                           "metadata": {"name": module.LOCK, "namespace": "prod", "resourceVersion": str(self.lease_version)},
                           "spec": dict(self.lease)})

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
        if verb in ("create", "replace"):
            if "kind: Job" in stdin:
                key, run, body = f"job/{module.JOB}", RUN_RE.search(stdin).group(1), stdin
            else:
                obj = json.loads(stdin)
                key = f"{obj['kind'].lower()}/{obj['metadata']['name']}"
                run, body = obj["metadata"].get("labels", {}).get(module.RUN_LABEL, ""), obj
            if key == "lease/" + module.LOCK:
                if verb == "create":
                    if self.lease is not None:
                        return 1, "", "Error from server (AlreadyExists)"
                elif obj["metadata"].get("resourceVersion") != str(self.lease_version):
                    return 1, "", "Error from server (Conflict)"
                self.lease = dict(obj["spec"])
                self.lease_version += 1
                return 0, "", ""
            if key == self.fail_create:
                return 1, "", "Error from server (Forbidden)"
            if key in self.objects:
                return 1, "", "Error from server (AlreadyExists)"
            self.objects[key], self.bodies[key] = run, body
            self.created.append(key)
            return 0, f"{key} created", ""
        if verb == "get" and rest[0] == "lease":
            if self.lease is None:
                return 1, "", "Error from server (NotFound)"
            return 0, self.lease_json(), ""
        if verb == "get" and rest[0] == "job" and rest[1] == module.JOB and f"job/{module.JOB}" in self.objects \
                and "json" in rest and self.job_result != "label-only":
            if self.job_result == "interrupt":
                self.job_result = "label-only"
                raise KeyboardInterrupt
            status = {"ok": {"succeeded": 1}, "failed": {"failed": 1}, "timeout": {}, "label-only": {}}[self.job_result]
            return 0, json.dumps({"status": status, "metadata": {"labels": {module.RUN_LABEL: self.objects[f"job/{module.JOB}"]}}}), ""
        if verb == "get" and rest[0] == "pod":
            return 0, "", ""
        if verb == "get":
            key = f"{rest[0]}/{rest[1]}"
            if key in self.objects:
                return 0, json.dumps({"metadata": {"labels": {module.RUN_LABEL: self.objects[key]}}}), ""
            return 1, "", f'Error from server (NotFound): {rest[0]} "{rest[1]}" not found'
        if verb == "delete":
            key = f"{rest[0]}/{rest[1]}"
            if key == "lease/" + module.LOCK:
                self.lease = None
                return 0, "", ""
            if key not in self.stuck and key in self.objects:
                self.objects.pop(key)
                self.deleted.append(key)
            return 0, "", ""
        if verb == "wait":
            return 0, "", ""
        if verb == "logs":
            return 0, ("db-bootstrap 완료 (_prod)\ncheck environment suffix _prod, content db content_db_prod\n"
                       "psql:/bootstrap/db-bootstrap.sql:9: ERROR: x LINE 1: ALTER ROLE a PASSWORD 'SCRAM-SHA-256$4096:abc$def:ghi'\n"
                       "noise line\n"), ""
        raise AssertionError(c)


class BootstrapTests(unittest.TestCase):
    def operator(self, fake, action="apply", confirm="prod", recover=False):
        op = module.ProdDbBootstrap.__new__(module.ProdDbBootstrap)
        op.args = SimpleNamespace(action=action, confirm_env=confirm, profile="p", cluster_name="ureka-eks",
                                  context="ureka-eks", expected_account_id=ACCOUNT, max_wait=1, poll=0,
                                  recover_stale_lock=recover)
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
            except KeyboardInterrupt:
                rc, error = None, "KeyboardInterrupt"
        printed = out.getvalue() + err.getvalue() + (error or "")
        secrets = [MASTER_PW, LEAK] + [v for k, v in fake.app.items() if "PASSWORD" in k and v]
        for value in secrets:
            self.assertNotIn(value, printed)
            for call in fake.calls:
                self.assertNotIn(value, " ".join(call), "값·ARN이 명령 인자에 실렸습니다")
        self.assertNotIn("SCRAM-SHA-256$4096", printed)
        return rc, error, printed

    def test_apply_creates_runs_and_cleans_up(self):
        fake = FakeCluster()
        rc, error, printed = self.execute(fake)
        self.assertEqual((rc, error), (0, None), printed)
        # 해시 Secret → ConfigMap → 마스터 Secret → Job 순서, 모두 같은 실행 표시
        self.assertEqual(fake.created, [f"secret/{module.ACCOUNTS_SECRET}", f"configmap/{module.CONFIGMAP}",
                                        f"secret/{module.MASTER_SECRET}", f"job/{module.JOB}"])
        runs = {RUN_RE.search(b).group(1) if isinstance(b, str) else b["metadata"]["labels"][module.RUN_LABEL]
                for b in fake.bodies.values()}
        self.assertEqual(len(runs), 1)
        self.assertRegex(runs.pop(), r"^[0-9a-f]{32}$")
        # 모두 지워졌고 잠금도 풀렸다
        self.assertEqual(fake.objects, {})
        self.assertIsNone(fake.lease)
        self.assertIn("정리 확인", printed)
        # 해시는 각 비밀번호의 SCRAM verifier다(원문 없음)
        accounts = fake.bodies[f"secret/{module.ACCOUNTS_SECRET}"]
        hashes = {k: base64.b64decode(v).decode() for k, v in accounts["data"].items()}
        self.assertEqual(set(hashes), set(module.HASHES.values()))
        for prop, var in module.HASHES.items():
            salt = base64.b64decode(hashes[var].split(":")[1].split("$")[0])
            self.assertEqual(hashes[var], module.scram(fake.app[prop], salt))
            self.assertNotIn(fake.app[prop], json.dumps(accounts))
        master = {k: base64.b64decode(v).decode() for k, v in fake.bodies[f"secret/{module.MASTER_SECRET}"]["data"].items()}
        self.assertEqual(master, {"PGUSER": "ureka_master", "PGPASSWORD": MASTER_PW})
        job = fake.bodies[f"job/{module.JOB}"]
        self.assertIn(f"value: {HOST}\n", job)
        self.assertNotIn("RDS_ENDPOINT", job)
        self.assertNotIn("RUN_ID", job)
        cm = fake.bodies[f"configmap/{module.CONFIGMAP}"]["data"]
        self.assertEqual(cm["db-bootstrap.sql"], module.SQL_FILE.read_text())
        # 로그 요약: 확인·오류 줄만, 해시는 가림
        self.assertIn("check environment suffix _prod", printed)
        self.assertIn("SCRAM-SHA-256$<생략>", printed)
        self.assertNotIn("noise line", printed)
        # 마스터 비밀은 잠금을 잡은 뒤에만 읽는다
        lock_at = next(i for i, c in enumerate(fake.calls) if c[0] == "kubectl" and c[6] == "create")
        master_at = next(i for i, c in enumerate(fake.calls) if "--cli-input-json" in c)
        self.assertLess(lock_at, master_at)
        self.assertIn('"kind": "Lease"', fake.stdins[lock_at])

    def test_job_failure_still_cleans_up(self):
        fake = FakeCluster(job_result="failed")
        rc, error, printed = self.execute(fake)
        self.assertEqual(rc, 1)
        self.assertEqual(fake.objects, {})
        self.assertIsNone(fake.lease)
        self.assertIn("실패", printed)

    def test_timeout_still_cleans_up(self):
        fake = FakeCluster(job_result="timeout")
        rc, _, printed = self.execute(fake)
        self.assertEqual(rc, 1)
        self.assertEqual(fake.objects, {})

    def test_interrupt_cleans_up_and_reraises(self):
        fake = FakeCluster(job_result="interrupt")
        rc, error, printed = self.execute(fake)
        self.assertEqual(error, "KeyboardInterrupt")
        self.assertEqual(fake.objects, {})
        self.assertIsNone(fake.lease)

    def test_cleanup_failure_is_loud(self):
        fake = FakeCluster(stuck=[f"secret/{module.MASTER_SECRET}"])
        rc, _, printed = self.execute(fake)
        self.assertEqual(rc, 3)
        self.assertIn(f"secret/{module.MASTER_SECRET}", printed)
        self.assertIn("경고", printed)

    def test_cleanup_failure_wins_over_other_errors(self):
        """실행 오류와 정리 실패가 겹치면 3(자격 잔존)을 돌려준다(검토 P2-2)."""
        stuck = [f"secret/{module.MASTER_SECRET}"]
        cases = {
            "Job CREATE 거부": FakeCluster(stuck=stuck, fail_create=f"job/{module.JOB}"),
            "시간 초과": FakeCluster(stuck=stuck, job_result="timeout"),
            "Job 실패": FakeCluster(stuck=stuck, job_result="failed"),
            "Ctrl+C/SIGTERM": FakeCluster(stuck=stuck, job_result="interrupt"),
        }
        for name, fake in cases.items():
            with self.subTest(name):
                rc, error, printed = self.execute(fake)
                self.assertEqual((rc, error), (3, None), printed)
                self.assertIn(f"secret/{module.MASTER_SECRET}", printed)
                self.assertIn(f"secret/{module.MASTER_SECRET}", fake.objects)  # 실제로 남아 있는 경우
                self.assertIsNone(fake.lease)  # 잠금은 풀어 다음 실행이 시작 정리를 할 수 있게

    def test_interrupt_during_cleanup_is_ignored(self):
        fake = FakeCluster()
        op = self.operator(fake)
        seen = []
        original = op.cleanup

        def cleanup(run_id):
            seen.append((module.signal.getsignal(module.signal.SIGINT), module.signal.getsignal(module.signal.SIGTERM)))
            return original(run_id)
        op.cleanup = cleanup
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(module.time, "sleep"):
            self.assertEqual(op.execute(), 0)
        self.assertEqual(seen[-1], (module.signal.SIG_IGN, module.signal.SIG_IGN))
        self.assertNotEqual(module.signal.getsignal(module.signal.SIGINT), module.signal.SIG_IGN)  # 끝나면 되돌림

    def test_leftovers_of_finished_run_are_removed_under_lock(self):
        old = "b" * 32
        fake = FakeCluster(leftovers={f"secret/{module.MASTER_SECRET}": old, f"job/{module.JOB}": old})
        rc, _, _ = self.execute(fake)
        self.assertEqual(rc, 0)
        self.assertIn(f"secret/{module.MASTER_SECRET}", fake.deleted)

    def test_undeletable_leftover_stops_before_master_with_code_3(self):
        fake = FakeCluster(leftovers={f"job/{module.JOB}": "b" * 32}, stuck=[f"job/{module.JOB}"])
        rc, error, printed = self.execute(fake)
        self.assertEqual(rc, 3)
        self.assertIn("마스터 비밀을 읽지 않고", printed)
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))
        self.assertEqual(fake.created, [])
        self.assertIsNone(fake.lease)

    def test_active_run_is_never_touched(self):
        """다른 실행 A가 잠금을 갖고 있으면 B는 아무것도 지우지 않고 멈춘다(검토 P2-1)."""
        a = "a" * 32
        resources = {f"job/{module.JOB}": a, f"secret/{module.MASTER_SECRET}": a,
                     f"secret/{module.ACCOUNTS_SECRET}": a, f"configmap/{module.CONFIGMAP}": a}
        lease = {"holderIdentity": a, "acquireTime": module.micro_time()}
        for recover in (False, True):  # 새 잠금은 --recover-stale-lock으로도 넘겨받지 않는다
            fake = FakeCluster(leftovers=resources, lease=dict(lease))
            rc, error, _ = self.execute(fake, recover=recover)
            self.assertIsNone(rc)
            self.assertIn("다른 bootstrap 실행" if not recover else "넘겨받지 않습니다", error)
            self.assertEqual(fake.objects, resources)
            self.assertEqual(fake.deleted, [])
            self.assertEqual(fake.lease["holderIdentity"], a)
            self.assertFalse(any("--cli-input-json" in c for c in fake.calls))

    def test_two_overlapping_runs_share_one_cluster(self):
        """A가 Job을 기다리는 동안 B가 시작해도 A의 자원은 그대로이고, A는 끝까지 자기 자원만 정리한다."""
        fake = FakeCluster(job_result="label-only")  # A의 Job은 끝나지 않은 채로 B가 끼어든다
        a, b = self.operator(fake), self.operator(fake)
        b_results = []
        original_wait = a.wait_job

        def wait_with_b():
            snapshot = dict(fake.objects)
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(out):
                try:
                    b_results.append(b.execute())
                except module.SafeError as error:
                    b_results.append(str(error))
            self.assertEqual(fake.objects, snapshot, "B가 A의 자원을 바꿨습니다")
            return "ok"
        a.wait_job = wait_with_b
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(module.time, "sleep"):
            self.assertEqual(a.execute(), 0)
        self.assertIn("다른 bootstrap 실행", b_results[0])
        self.assertEqual(fake.objects, {})
        self.assertIsNone(fake.lease)

    def test_final_cleanup_skips_resources_of_another_run(self):
        fake = FakeCluster(leftovers={f"secret/{module.MASTER_SECRET}": "c" * 32})
        op = self.operator(fake)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), patch.object(module.time, "sleep"):
            failed, foreign = op.cleanup("d" * 32)
        self.assertEqual(failed, [])
        self.assertEqual(foreign, [f"secret/{module.MASTER_SECRET}"])
        self.assertIn(f"secret/{module.MASTER_SECRET}", fake.objects)

    def test_stale_lock_needs_flag_and_is_taken_atomically(self):
        old = {"holderIdentity": "e" * 32, "acquireTime": module.micro_time(module.time.time() - 3600)}
        fake = FakeCluster(lease=dict(old))
        rc, error, _ = self.execute(fake)
        self.assertIn("다른 bootstrap 실행", error)
        self.assertEqual(fake.lease["holderIdentity"], "e" * 32)
        fake = FakeCluster(lease=dict(old))
        rc, error, printed = self.execute(fake, recover=True)
        self.assertEqual((rc, error), (0, None), printed)
        self.assertTrue(any(c[0] == "kubectl" and c[6] == "replace" for c in fake.calls))
        self.assertIsNone(fake.lease)

    def test_stale_lock_takeover_conflict_stops(self):
        old = {"holderIdentity": "e" * 32, "acquireTime": module.micro_time(module.time.time() - 3600)}
        fake = FakeCluster(lease=dict(old))
        fake.lease_version = 7  # get 뒤 누군가 바꾼 것처럼 replace의 resourceVersion이 맞지 않게
        original = fake.lease_json
        fake.lease_json = lambda: original().replace('"resourceVersion": "7"', '"resourceVersion": "6"')
        rc, error, _ = self.execute(fake, recover=True)
        self.assertIn("넘겨받지 못했습니다", error)
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))

    def test_lock_age(self):
        now = 1_800_000_000
        self.assertEqual(module.lock_age({"spec": {"acquireTime": module.micro_time(now - 120)}}, now), 120)
        self.assertIsNone(module.lock_age({"spec": {}}, now))

    def test_check_reads_no_master_and_creates_nothing(self):
        fake = FakeCluster()
        rc, error, printed = self.execute(fake, action="check", confirm=None)
        self.assertEqual((rc, error), (0, None))
        self.assertFalse(any("--cli-input-json" in c for c in fake.calls))
        self.assertFalse(any(c[0] == "kubectl" and c[6] in ("create", "delete") for c in fake.calls))
        self.assertIn("변경 없음", printed)
        self.assertIn("실행 잠금: 없음", printed)
        self.assertIsNone(fake.lease)

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
