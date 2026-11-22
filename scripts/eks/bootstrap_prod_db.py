#!/usr/bin/env python3
"""EKS prod 논리 DB·계정을 같은 RDS에 만든다(#63 후속, prod DB bootstrap). 여러 번 실행해도 같은 상태가 된다.

운영 PC에서 CN SSO 프로필·EKS kubectl 컨텍스트로 실행한다(시드 scripts/eks/seed_prod_secrets.py 뒤):
  python3 scripts/eks/bootstrap_prod_db.py check --profile ureka-admin                        변경 없음
  python3 scripts/eks/bootstrap_prod_db.py apply --profile ureka-admin --confirm-env prod     Job 실행

순서: 대상 확인(승인 계정·ACTIVE EKS·kubectl 컨텍스트·prod 네임스페이스 restricted) → 이전 실행 잔여물 삭제 확인
      → data 스택 output(마스터 비밀 ARN·RDS 엔드포인트) → ureka/eks/prod/app 읽기 → 비밀번호 6개의 SCRAM 해시 계산
      → [apply만] 마스터 비밀 읽기 → prod에 임시 Secret 2개(마스터·해시)·ConfigMap·Job → 완료 대기 → 로그 요약
      → 성공·실패·Ctrl+C 모두: Job·Pod·Secret 2개·ConfigMap을 지우고 사라졌는지 확인(못 지우면 경고, 종료 코드 3).
- 비밀번호 원문은 DB 서버로 가지 않는다(해시만). 값·해시·ARN은 화면·명령 인자·Git·로그 파일에 싣지 않는다.
  Secret·ConfigMap·Job은 kubectl 표준 입력으로만 넘기고, ARN은 aws 표준 입력(--cli-input-json)으로만 넘긴다.
- SQL은 kind·EC2 dev와 같은 environments/kind/data/db-bootstrap.sql이고 DB_SUFFIX=_prod로 prod 이름만 만든다.
- ESO 리더에는 마스터 비밀 권한을 주지 않는다. 마스터 비밀은 이 도구를 실행하는 CN SSO만 읽는다.
- 한계: SIGKILL·PC 종료·클러스터 불통이면 정리하지 못한다. 다음 실행이 시작할 때 남은 것을 먼저 지운다
  (Job은 ttlSecondsAfterFinished 10분 안전망도 있다). 남은 것 확인은 docs/eks-secrets.md 'prod DB bootstrap'.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import time

from operate import Operator, SafeError, ROOT
from bootstrap_argocd import verify_destination

NS = "prod"
APP_SECRET = "ureka/eks/prod/app"
JOB = "db-bootstrap-prod"
CONFIGMAP = "db-bootstrap-prod"
MASTER_SECRET = "db-bootstrap-prod-master"
ACCOUNTS_SECRET = "db-bootstrap-prod-accounts"
JOB_FILE = ROOT / "environments/eks/prod/db-bootstrap/job.yaml"
SQL_FILE = ROOT / "environments/kind/data/db-bootstrap.sql"
RUN_FILE = ROOT / "environments/kind/data/run-bootstrap.sh"
DATA_STACK = ROOT / "infra/environments/data"
PLACEHOLDER = "            - name: PGHOST\n              value: RDS_ENDPOINT\n"
# 묶음 속성 → Job이 읽는 해시 변수(db-bootstrap.sql \getenv). 계정 이름은 SQL이 접미사로 만든다.
HASHES = {
    "AUTH_DB_PASSWORD": "AUTH_DB_APP_SCRAM",
    "CONTENT_DB_PASSWORD": "CONTENT_DB_APP_SCRAM",
    "RECOMMEND_DB_PASSWORD": "CONTENT_DB_RECOMMEND_SCRAM",
    "INGEST_DB_PASSWORD": "CONTENT_DB_INGEST_SCRAM",
    "CHAT_DB_PASSWORD": "CHAT_DB_APP_SCRAM",
    "OPS_DB_PASSWORD": "OPS_DB_APP_SCRAM",
}
# 시드가 넣은 prod 계정 이름과 SQL(접미사 _prod)이 만드는 이름이 같아야 한다. dev 이름이면 멈춘다.
EXPECTED_USERNAMES = {"RECOMMEND_DB_USERNAME": "content_db_prod_recommend", "INGEST_DB_USERNAME": "content_db_prod_ingest"}
ARN_RE = re.compile(r"arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:rds![A-Za-z0-9-]+")
HOST_RE = re.compile(r"[a-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws\.com")
SCRAM_RE = re.compile(r"SCRAM-SHA-256\$[^\s']*")
MAX_WAIT = 600


def scram(password, salt=None):
    """PostgreSQL rolpassword 형식 SCRAM-SHA-256 verifier(create-secrets.sh와 같은 계산, 4096회)."""
    salt = salt or os.urandom(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 4096)
    client = hmac.new(salted, b"Client Key", "sha256").digest()
    server = hmac.new(salted, b"Server Key", "sha256").digest()
    b64 = lambda raw: base64.b64encode(raw).decode()
    return "SCRAM-SHA-256$4096:%s$%s:%s" % (b64(salt), b64(hashlib.sha256(client).digest()), b64(server))


def account_hashes(bundle):
    for prop, expected in EXPECTED_USERNAMES.items():
        if bundle.get(prop) != expected:
            raise SafeError(f"{APP_SECRET}의 {prop}가 prod 계정 이름이 아닙니다. 시드 원본을 먼저 확인하세요.")
    hashes = {}
    for prop, var in HASHES.items():
        value = bundle.get(prop)
        if not isinstance(value, str) or len(value) < 32 or any(c.isspace() for c in value):
            raise SafeError(f"{APP_SECRET}의 {prop}가 비었거나 형식이 다릅니다(값은 출력하지 않음).")
        hashes[var] = scram(value)
    if len({bundle[p] for p in HASHES}) != len(HASHES):
        raise SafeError("prod DB 비밀번호가 서로 겹칩니다. 시드 원본을 확인하세요(값은 출력하지 않음).")
    return hashes


def secret_manifest(name, data):
    return json.dumps({
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {"name": name, "namespace": NS,
                     "labels": {"app.kubernetes.io/part-of": "ureka", "app.kubernetes.io/name": JOB}},
        "data": {k: base64.b64encode(v.encode()).decode() for k, v in data.items()},
    })


def configmap_manifest():
    return json.dumps({
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": CONFIGMAP, "namespace": NS,
                     "labels": {"app.kubernetes.io/part-of": "ureka", "app.kubernetes.io/name": JOB}},
        "data": {"db-bootstrap.sql": SQL_FILE.read_text(), "run-bootstrap.sh": RUN_FILE.read_text()},
    })


def job_manifest(host):
    if not HOST_RE.fullmatch(host or ""):
        raise SafeError("RDS 엔드포인트 형식이 아닙니다.")
    source = JOB_FILE.read_text()
    if source.count(PLACEHOLDER) != 1:
        raise SafeError("job.yaml의 PGHOST 자리를 찾지 못했습니다.")
    return source.replace(PLACEHOLDER, f"            - name: PGHOST\n              value: {host}\n")


def safe_log(text):
    """Job 로그에서 확인 줄·오류 줄만 남기고 SCRAM 해시는 가린다."""
    keep = []
    for line in (text or "").splitlines():
        if line.startswith("check ") or "ERROR" in line or "db-bootstrap" in line or "DB_SUFFIX" in line or "_SCRAM:" in line:
            keep.append(SCRAM_RE.sub("SCRAM-SHA-256$<생략>", line))
    return "\n".join(keep[-20:])


class ProdDbBootstrap(Operator):
    def k(self, *args):
        return ["kubectl", "--context", self.args.context, "-n", NS, "--request-timeout=20s", *args]

    def quiet(self, command, stdin=None, check=True):
        """값이 지나가는 명령. 실패해도 원문을 출력·기록하지 않는다(Operator.run과 달리 로그 파일 없음)."""
        result = subprocess.run(command, cwd=ROOT, env=self.env, input=stdin, capture_output=True, text=True)
        if check and result.returncode:
            match = re.search(r"\((AccessDenied[A-Za-z]*|[A-Za-z]+Exception|NotFound|Forbidden|AlreadyExists)\)",
                              result.stderr or "")
            raise SafeError(f"{command[0]} {' '.join(a for a in command[1:4] if not a.startswith('-'))} 실패"
                            f"{': ' + match.group(1) if match else ''}(원문은 출력하지 않음).")
        return result

    # --- 대상·입력 확인 -------------------------------------------------------
    def preflight(self):
        identity = self.identity()
        cluster = self.aws("eks", "describe-cluster", "--name", self.args.cluster_name)["cluster"]
        config = json.loads(self.run(["kubectl", "--context", self.args.context, "config", "view", "--minify", "-o", "json"]))
        verify_destination(cluster, config, identity["Account"], self.args.context)
        result = self.quiet(self.k("get", "namespace", NS, "-o", "json"), check=False)
        if result.returncode:
            raise SafeError("prod 네임스페이스가 없거나 조회하지 못했습니다(#62 먼저).")
        labels = json.loads(result.stdout)["metadata"].get("labels", {})
        if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
            raise SafeError("prod 네임스페이스가 Pod Security restricted가 아닙니다(#62 확인).")

    def data_outputs(self):
        result = self.quiet(["terraform", "-chdir=" + str(DATA_STACK), "output", "-json"], check=False)
        if result.returncode:
            raise SafeError("data 스택 output을 읽지 못했습니다. infra/environments/data를 backend.hcl로 init했는지 확인하세요.")
        outputs = json.loads(result.stdout)
        arn = outputs.get("master_secret_arn", {}).get("value", "")
        host = outputs.get("endpoint", {}).get("value", "")
        if not ARN_RE.fullmatch(arn):
            raise SafeError("data output master_secret_arn이 RDS 관리 비밀 ARN 형식이 아닙니다(값은 출력하지 않음).")
        if not HOST_RE.fullmatch(host):
            raise SafeError("data output endpoint가 RDS 엔드포인트 형식이 아닙니다.")
        return arn, host

    def read_secret(self, secret_id=None, arn=None):
        base = ["aws", "secretsmanager", "get-secret-value", "--profile", self.args.profile,
                "--region", "ap-northeast-2", "--output", "json"]
        if arn:  # ARN(계정 ID)은 명령 인자에 싣지 않는다
            result = self.quiet(base + ["--cli-input-json", "file:///dev/stdin"], stdin=json.dumps({"SecretId": arn}))
        else:
            result = self.quiet(base + ["--secret-id", secret_id])
        return json.loads(json.loads(result.stdout)["SecretString"])

    # --- 클러스터 자원 -----------------------------------------------------------
    def gone(self, kind, name):
        result = self.quiet(self.k("get", kind, name, "-o", "name"), check=False)
        if result.returncode == 0:
            return False
        return "(NotFound)" in result.stderr

    def delete_and_confirm(self, kind, name):
        for attempt in range(1, 4):
            self.quiet(self.k("delete", kind, name, "--ignore-not-found", "--wait=true", "--timeout=60s",
                              *(["--cascade=foreground"] if kind == "job" else [])), check=False)
            if self.gone(kind, name):
                return True
            time.sleep(attempt * 2)
        return False

    def pods_gone(self):
        self.quiet(self.k("wait", "--for=delete", "pod", "-l", f"job-name={JOB}", "--timeout=60s"), check=False)
        result = self.quiet(self.k("get", "pod", "-l", f"job-name={JOB}", "-o", "name"), check=False)
        if result.returncode:
            return None  # 알 수 없음
        return not result.stdout.strip()

    def cleanup(self):
        """Job·Pod를 먼저 지우고(마스터 비밀번호를 env로 들고 있는 Pod) Secret·ConfigMap을 지운다. 실패 목록을 돌려준다."""
        failed = []
        if not self.delete_and_confirm("job", JOB):
            failed.append(f"job/{JOB}")
        pods = self.pods_gone()
        if pods is not True:
            failed.append(f"pod -l job-name={JOB}" + (" (조회 실패)" if pods is None else ""))
        for kind, name in (("secret", MASTER_SECRET), ("secret", ACCOUNTS_SECRET), ("configmap", CONFIGMAP)):
            if not self.delete_and_confirm(kind, name):
                failed.append(f"{kind}/{name}")
        return failed

    def wait_job(self):
        deadline = time.monotonic() + self.args.max_wait
        while time.monotonic() < deadline:
            result = self.quiet(self.k("get", "job", JOB, "-o", "json"), check=False)
            if result.returncode == 0:
                status = json.loads(result.stdout).get("status", {})
                if status.get("succeeded") == 1:
                    return "ok"
                if status.get("failed"):
                    return "failed"
            time.sleep(self.args.poll)
        return "timeout"

    # --- 실행 -------------------------------------------------------------------
    def execute(self):
        if self.args.action == "apply" and self.args.confirm_env != NS:
            raise SafeError("실제 실행은 --confirm-env prod를 명시해야 합니다.")
        self.preflight()
        arn, host = self.data_outputs()
        hashes = account_hashes(self.read_secret(secret_id=APP_SECRET))
        manifest = job_manifest(host)
        if self.args.action == "check":
            print("확인 완료(변경 없음): 대상 EKS·prod 네임스페이스·data output·prod 묶음 형식. "
                  "마스터 비밀은 읽지 않았습니다.")
            return 0

        # 0) 이전 실행이 남긴 것을 먼저 지운다. 남아 있으면 마스터 비밀을 읽지 않고 멈춘다.
        leftovers = self.cleanup()
        if leftovers:
            raise SafeError("이전 실행이 남긴 자원을 지우지 못했습니다: " + ", ".join(leftovers) + ". 마스터 비밀을 읽지 않고 멈춥니다.")

        result, rc = None, 0
        try:
            master = self.read_secret(arn=arn)
            user, password = master.get("username", ""), master.get("password", "")
            master = None
            if not user or not password:
                raise SafeError("마스터 비밀에 username·password가 없습니다(값은 출력하지 않음).")
            # 해시 Secret을 먼저, 마스터 Secret은 Job 바로 앞에 만든다. create라 같은 이름이 있으면 덮어쓰지 않고 실패한다.
            self.quiet(self.k("create", "-f", "-"), stdin=secret_manifest(ACCOUNTS_SECRET, hashes))
            self.quiet(self.k("create", "-f", "-"), stdin=configmap_manifest())
            self.quiet(self.k("create", "-f", "-"), stdin=secret_manifest(MASTER_SECRET, {"PGUSER": user, "PGPASSWORD": password}))
            user = password = None
            self.quiet(self.k("create", "-f", "-"), stdin=manifest)
            print(f"Job {JOB} 실행 중(최대 {self.args.max_wait // 60}분)...", flush=True)
            result = self.wait_job()
            logs = self.quiet(self.k("logs", f"job/{JOB}", "--tail=50"), check=False).stdout
            summary = safe_log(logs)
            if summary:
                print(summary)
            if result == "ok":
                print(f"{JOB} 완료. 임시 Secret·Job을 지웁니다.")
            elif result == "failed":
                print(f"{JOB} 실패. 위 요약을 확인하세요. 임시 Secret·Job을 지웁니다.", file=sys.stderr)
                rc = 1
            else:
                print(f"{self.args.max_wait}초 안에 끝나지 않았습니다. 임시 Secret·Job을 지웁니다.", file=sys.stderr)
                rc = 1
        finally:
            hashes.clear()
            failed = self.cleanup()
            if failed:
                print("경고: 지우지 못한 자원(마스터 비밀번호가 남았을 수 있음): " + ", ".join(failed) +
                      f". kubectl --context {self.args.context} -n {NS} delete <종류> <이름> 후 get으로 없어졌는지 확인하세요.",
                      file=sys.stderr)
                rc = 3
            else:
                print("정리 확인: Job·Pod·임시 Secret 2개·ConfigMap 없음.")
        if rc == 0:
            print("다음(docs/eks-secrets.md): prod 비밀 앱 등록 → ExternalSecret Ready → prod 앱 Sync(Flyway가 스키마를 만든다).")
        return rc


def interrupt(*_):
    raise KeyboardInterrupt


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Create EKS prod logical DBs/accounts on the shared RDS (no values printed).")
    parser.add_argument("action", choices=("check", "apply"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--cluster-name", default="ureka-eks")
    parser.add_argument("--context", default="ureka-eks")
    parser.add_argument("--confirm-env")
    parser.add_argument("--max-wait", type=int, default=MAX_WAIT, help=argparse.SUPPRESS)
    parser.add_argument("--poll", type=int, default=5, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, interrupt)  # SIGTERM도 Ctrl+C처럼 정리(finally)를 거친다
    try:
        args.expected_account_id = os.environ.get("UREKA_EXPECTED_ACCOUNT_ID", "")
        if not re.fullmatch(r"[0-9]{12}", args.expected_account_id):
            raise SafeError("환경 변수 UREKA_EXPECTED_ACCOUNT_ID에 승인 계정 ID(12자리)를 넣어 주세요(값은 출력하지 않음).")
        return ProdDbBootstrap(args).execute()
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("중단 요청으로 멈췄습니다. 위 정리 확인 메시지를 보세요(없으면 docs/eks-secrets.md 잔여물 확인).", file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, IndexError):
        print("중단: 접속·조회 결과 형식이 예상과 다릅니다(값은 출력하지 않음).", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
