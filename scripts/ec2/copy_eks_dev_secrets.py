#!/usr/bin/env python3
"""EC2 dev의 기존 서비스 Secret 값을 EKS dev 원본(Secrets Manager)으로 한 번 복사한다(#63, 방식 A).

EC2 서버 안(SSM 셸)에서 root로 실행한다:
  sudo python3 scripts/ec2/copy_eks_dev_secrets.py check              읽기·검사만(AWS·클러스터 변경 없음)
  sudo python3 scripts/ec2/copy_eks_dev_secrets.py copy               없으면 만든다. 이미 있으면 바꾸지 않고 멈춘다
  sudo python3 scripts/ec2/copy_eks_dev_secrets.py copy --update-existing
                                                                      EC2 값을 바꾼 뒤 EKS dev에 새 버전으로 맞춘다

- EC2 쪽 Secret·DB 비밀번호는 읽기만 하고 바꾸지 않는다. 새 값을 만들지 않는다.
- 만드는 비밀: ureka/eks/dev/app(서비스 값 묶음), ureka/eks/dev/chat-ai(EC2에 ureka-chat-ai가 있을 때만).
  JSON 속성 이름은 charts/ureka-eks-secrets/values.yaml의 bundles와 같다(tests/eks/test_copy_eks_dev_secrets.py가 비교).
- 쓰기 권한은 data 스택 eks_dev_secret_copy_enabled=true 동안만 있다(읽기 권한은 없다). 복사 뒤 끈다.
- 값은 화면·명령 인자·로그에 싣지 않는다. 임시 폴더(0700)의 파일을 aws CLI에 file://로만 넘기고 끝나면 지운다.
  aws 오류 원문에는 ARN(계정 ID)이 있어 예외 이름만 보여 준다.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

NAMESPACE = "dev"
PREFIX = "ureka/eks/dev"
# 만들 Kubernetes Secret → 키 → 묶음 JSON 속성. charts/ureka-eks-secrets/values.yaml bundles와 같아야 한다.
BUNDLES = {
    "app": {
        "ureka-auth-secrets": {
            "DB_PASSWORD": "AUTH_DB_PASSWORD", "JWT_PRIVATE_KEY": "JWT_PRIVATE_KEY",
            "JWT_PUBLIC_KEY": "JWT_PUBLIC_KEY", "EMAIL_CODE_SECRET": "EMAIL_CODE_SECRET",
            "INTERNAL_SERVICE_TOKEN": "INTERNAL_SERVICE_TOKEN",
        },
        "ureka-content-secrets": {
            "DB_PASSWORD": "CONTENT_DB_PASSWORD", "JWT_PUBLIC_KEY": "JWT_PUBLIC_KEY",
            "INTERNAL_SERVICE_TOKEN": "INTERNAL_SERVICE_TOKEN",
        },
        "ureka-chat-secrets": {
            "DB_PASSWORD": "CHAT_DB_PASSWORD", "JWT_PUBLIC_KEY": "JWT_PUBLIC_KEY",
            "INTERNAL_SERVICE_TOKEN": "INTERNAL_SERVICE_TOKEN",
        },
        "ureka-ops-secrets": {"DB_PASSWORD": "OPS_DB_PASSWORD", "JWT_PUBLIC_KEY": "JWT_PUBLIC_KEY"},
        "ureka-recommend-secrets": {"INTERNAL_SERVICE_TOKEN": "INTERNAL_SERVICE_TOKEN"},
        "ureka-recommend-db": {"DB_USERNAME": "RECOMMEND_DB_USERNAME", "DB_PASSWORD": "RECOMMEND_DB_PASSWORD"},
        "ureka-ingest-db": {"DB_USERNAME": "INGEST_DB_USERNAME", "DB_PASSWORD": "INGEST_DB_PASSWORD"},
    },
    "chat-ai": {"ureka-chat-ai": {"AI_MODE": "AI_MODE", "AI_API_KEY": "AI_API_KEY"}},
}
OPTIONAL_BUNDLES = {"chat-ai"}
# 이름이 정해진 계정(create-secrets.sh·db-bootstrap.sql). 다른 값이면 원본이 잘못된 것이라 멈춘다.
EXPECTED_PLAIN = {"RECOMMEND_DB_USERNAME": "content_db_recommend", "INGEST_DB_USERNAME": "content_db_ingest"}
TAGS = ["Key=Project,Value=ureka", "Key=Stack,Value=eks-dev-secrets", "Key=ManagedBy,Value=copy_eks_dev_secrets",
        "Key=Source,Value=kdt-ureka/ureka-gitops"]


class SafeError(Exception):
    """값·ARN이 없는, 화면에 보여도 되는 메시지."""


class Runner:
    def __init__(self, env):
        self.env = env

    def __call__(self, command, check=True):
        result = subprocess.run(command, env=self.env, capture_output=True, text=True)
        if check and result.returncode:
            raise SafeError(f"{command[0]} 실행 실패{exception_name(result.stderr)}(원문은 값·ARN이 있을 수 있어 출력하지 않음).")
        return result


def exception_name(stderr):
    match = re.search(r"\((AccessDenied[A-Za-z]*|[A-Za-z]+Exception|NotFound|Forbidden)\)", stderr or "")
    return f": {match.group(1)}" if match else ""


def read_sources(run, bundle):
    """bundle의 Kubernetes Secret을 읽는다. 없으면 None(선택 묶음) 또는 SafeError."""
    found = {}
    for name in BUNDLES[bundle]:
        result = run(["kubectl", "--context", "default", "-n", NAMESPACE, "--request-timeout=20s",
                      "get", "secret", name, "-o", "json"], check=False)
        if result.returncode:
            if "(NotFound)" in result.stderr:
                found[name] = None
                continue
            raise SafeError(f"Secret {name} 조회 실패{exception_name(result.stderr)}. 없음으로 보지 않고 멈춥니다.")
        data = json.loads(result.stdout).get("data") or {}
        found[name] = data
    missing = [n for n, d in found.items() if d is None]
    if missing:
        if bundle in OPTIONAL_BUNDLES and len(missing) == len(found):
            return None
        raise SafeError(f"EC2 dev Secret이 없습니다: {', '.join(missing)}. EC2에서 새로 만들지 말고 상태를 먼저 확인하세요.")
    return found


def build_bundle(bundle, sources):
    """같은 속성을 쓰는 Secret 값이 모두 같은지 보고 JSON 묶음을 만든다. 오류에는 이름만 싣는다."""
    values = {}
    for secret, keys in BUNDLES[bundle].items():
        data = sources[secret]
        for key, prop in keys.items():
            if key not in data:
                raise SafeError(f"{secret}에 키 {key}가 없습니다.")
            try:
                value = base64.b64decode(data[key], validate=True).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                raise SafeError(f"{secret}.{key}를 해석하지 못했습니다(값은 출력하지 않음).") from None
            if not value:
                raise SafeError(f"{secret}.{key}가 비어 있습니다.")
            if prop in values and values[prop] != value:
                raise SafeError(f"{prop} 값이 Secret마다 다릅니다({secret}.{key}). EC2 원본을 먼저 맞추세요.")
            values[prop] = value
    for prop, expected in EXPECTED_PLAIN.items():
        if prop in values and values[prop] != expected:
            raise SafeError(f"{prop}가 예상 계정 이름이 아닙니다.")
    return values


def remote_state(run, name, region):
    """'absent' | 'present'. 삭제 예약된 비밀·권한 오류는 멈춘다."""
    result = run(["aws", "secretsmanager", "describe-secret", "--region", region, "--secret-id", name,
                  "--output", "json"], check=False)
    if result.returncode:
        if "ResourceNotFoundException" in result.stderr:
            return "absent"
        raise SafeError(f"{name} 확인 실패{exception_name(result.stderr)}. 쓰기 권한이 켜졌는지 확인하세요(data 스택).")
    if json.loads(result.stdout).get("DeletedDate"):
        raise SafeError(f"{name}가 삭제 예약 상태입니다. 복구(restore-secret) 여부를 먼저 정하세요.")
    return "present"


def write_remote(run, name, region, path, state, update_existing):
    secret_string = "file://" + str(path)
    if state == "absent":
        run(["aws", "secretsmanager", "create-secret", "--region", region, "--name", name,
             "--description", "EKS dev app secrets copied from EC2 dev (gitops#63). Values never in Git.",
             "--secret-string", secret_string, "--tags", *TAGS, "--output", "json"])
        return "생성"
    if not update_existing:  # copy()가 먼저 막지만, 단독 호출에도 덮어쓰지 않는다
        raise SafeError(f"{name}가 이미 있습니다. 바꾸지 않았습니다(EC2 값을 바꾼 경우에만 --update-existing).")
    run(["aws", "secretsmanager", "put-secret-value", "--region", region, "--secret-id", name,
         "--secret-string", secret_string, "--output", "json"])
    return "새 버전"


def copy(run, region, action, update_existing, workdir):
    plans = []
    for bundle in BUNDLES:
        sources = read_sources(run, bundle)
        if sources is None:
            print(f"{PREFIX}/{bundle}: EC2에 원본 Secret이 없어 건너뜁니다(선택 묶음).")
            continue
        plans.append((bundle, build_bundle(bundle, sources)))
    # 모두 읽고 검사한 뒤에만 AWS를 건드린다(하나라도 틀리면 아무것도 쓰지 않음).
    states = {bundle: remote_state(run, f"{PREFIX}/{bundle}", region) for bundle, _ in plans}
    if action == "copy" and not update_existing:
        present = [b for b, s in states.items() if s == "present"]
        if present:
            raise SafeError("이미 있는 비밀: " + ", ".join(f"{PREFIX}/{b}" for b in present) +
                            ". 아무것도 바꾸지 않았습니다(EC2 값을 바꾼 경우에만 --update-existing).")
    for bundle, values in plans:
        name = f"{PREFIX}/{bundle}"
        if action == "check":
            print(f"{name}: 키 {len(values)}개 검사 통과, 원격 {'있음' if states[bundle] == 'present' else '없음'} (변경 없음)")
            continue
        path = Path(workdir) / f"{bundle}.json"
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(values, f)
        try:
            done = write_remote(run, name, region, path, states[bundle], update_existing)
        finally:
            path.unlink(missing_ok=True)
        print(f"{name}: 키 {len(values)}개 {done}")
        values.clear()


def region_from(marker):
    try:
        text = Path(marker).read_text()
    except OSError:
        raise SafeError(f"{marker}이 없습니다. EC2 dev 서버 안에서 실행하세요.") from None
    match = re.search(r"^AWS_REGION=([a-z]{2}-[a-z]+-[0-9])$", text, re.M)
    if not match:
        raise SafeError(f"{marker}의 AWS_REGION 형식이 아닙니다.")
    return match.group(1)


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Copy EC2 dev Secrets to ureka/eks/dev/* (no new values).")
    parser.add_argument("action", choices=("check", "copy"))
    parser.add_argument("--update-existing", action="store_true")
    args = parser.parse_args(argv)
    etc = os.environ.get("UREKA_ETC_DIR", "/etc/ureka")  # 시험에서만 바꾼다
    lock_path = os.environ.get("UREKA_LOCK_FILE", "/run/lock/ureka-eks-dev-secret-copy.lock")
    workdir = None
    try:
        if os.geteuid() != 0 and "UREKA_ETC_DIR" not in os.environ:
            raise SafeError("root로 실행하세요: sudo python3 scripts/ec2/copy_eks_dev_secrets.py check")
        region = region_from(os.path.join(etc, "registry.env"))
        for tool in ("kubectl", "aws"):
            if not shutil.which(tool, path=os.environ.get("PATH", "") + ":/usr/local/bin"):
                raise SafeError(f"{tool}가 필요합니다.")
        env = dict(os.environ, KUBECONFIG=os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml"), AWS_PAGER="",
                   PATH=os.environ.get("PATH", "") + ":/usr/local/bin")
        lock = open(lock_path, "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SafeError("다른 복사가 실행 중입니다.") from None
        workdir = tempfile.mkdtemp(prefix="eks-dev-copy-")
        copy(Runner(env), region, args.action, args.update_existing, workdir)
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError):
        print("중단: 조회 결과 형식이 예상과 다릅니다(값은 출력하지 않음).", file=sys.stderr)
        return 1
    finally:
        if workdir:
            shutil.rmtree(workdir, ignore_errors=True)
    if args.action == "copy":
        print("완료. 값은 출력하지 않았습니다. data 스택 eks_dev_secret_copy_enabled=false로 되돌려 apply하세요.")
    else:
        print("확인 완료. 변경 없음.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
