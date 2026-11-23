#!/usr/bin/env python3
"""EKS prod 비밀 묶음 ureka/eks/prod/app을 새 값으로 한 번 만든다(#63 후속, 시드).

운영 PC에서 CN SSO 프로필로 실행한다(EKS가 꺼져 있어도 된다):
  python3 scripts/eks/seed_prod_secrets.py check  --profile ureka-admin                    읽기만(변경 없음)
  python3 scripts/eks/seed_prod_secrets.py create --profile ureka-admin --confirm-env prod  없을 때만 만든다

- 승인 계정 ID는 인자가 아니라 환경 변수 UREKA_EXPECTED_ACCOUNT_ID로 받고 STS 결과와 비교한다(register_secrets_app.py와 같음).
- 속성 12개는 charts/ureka-eks-secrets/values.yaml bundles.app과 같다(tests/eks/test_seed_prod_secrets.py가 비교).
  DB 비밀번호 6개·EMAIL_CODE_SECRET·INTERNAL_SERVICE_TOKEN은 Secrets Manager get-random-password(영문·숫자 64자)가 만든다.
  JWT 키 쌍(RSA 2048)만 0700 임시 폴더에서 openssl로 만들고 바로 지운다. 계정 이름 2개는 정해진 prod 이름이다.
- 값은 화면·명령 인자·Git·로그에 싣지 않는다. 묶음 JSON은 aws CLI 표준 입력(file:///dev/stdin)으로만 넘긴다.
  aws 오류 원문에는 ARN(계정 ID)이 있을 수 있어 예외 이름만 보여 준다.
- 이미 있으면(삭제 예약 포함) 아무것도 만들지 않고 멈춘다. 덮어쓰기·교체 기능은 없다(교체는 DB 비밀번호와 함께 별도 절차).
- SES SMTP 자격은 이 묶음에 넣지 않는다(별도 비밀 ureka/eks/prod/ses-smtp, scripts/ses/create-smtp-secret.py).
- prod Gemini 키(ureka/eks/prod/chat-ai)도 만들지 않는다(키 담당·시점이 다르다).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

REGION = "ap-northeast-2"
NAME = "ureka/eks/prod/app"
# get-random-password로 만드는 값. 64자 영문·숫자(약 380비트): JDBC URL·셸·YAML에서 따옴표 문제가 없다.
RANDOM_PROPERTIES = (
    "AUTH_DB_PASSWORD", "CONTENT_DB_PASSWORD", "CHAT_DB_PASSWORD", "OPS_DB_PASSWORD",
    "RECOMMEND_DB_PASSWORD", "INGEST_DB_PASSWORD", "EMAIL_CODE_SECRET", "INTERNAL_SERVICE_TOKEN",
)
# 정해진 prod 계정 이름(db-bootstrap.sql 접미사 _prod, docs/eks-secrets.md 'prod DB·계정').
USERNAMES = {"RECOMMEND_DB_USERNAME": "content_db_prod_recommend", "INGEST_DB_USERNAME": "content_db_prod_ingest"}
JWT_PROPERTIES = ("JWT_PRIVATE_KEY", "JWT_PUBLIC_KEY")
PROPERTIES = frozenset(RANDOM_PROPERTIES) | frozenset(USERNAMES) | frozenset(JWT_PROPERTIES)
PASSWORD_LENGTH = 64
TAGS = ["Key=Project,Value=ureka", "Key=Stack,Value=eks-prod-secrets", "Key=ManagedBy,Value=seed_prod_secrets",
        "Key=Source,Value=kdt-ureka/ureka-gitops"]
DESCRIPTION = "EKS prod app secrets (gitops#63 seed). Generated values; never in Git or on screen."


class SafeError(Exception):
    """값·ARN이 없는, 화면에 보여도 되는 메시지."""


def exception_name(stderr):
    match = re.search(r"\((AccessDenied[A-Za-z]*|[A-Za-z]+Exception|[A-Za-z]+Error|NotFound|Forbidden)\)", stderr or "")
    return f": {match.group(1)}" if match else ""


def clean_env(profile):
    env = dict(os.environ, AWS_PROFILE=profile, AWS_REGION=REGION, AWS_DEFAULT_REGION=REGION, AWS_PAGER="")
    for name in list(env):
        if name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
                    "AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_DEFAULT_PROFILE") \
                or name.startswith(("AWS_ENDPOINT_URL", "AWS_CONTAINER_CREDENTIALS")):
            env.pop(name, None)
    env["AWS_DEFAULT_PROFILE"] = profile
    return env


class Runner:
    """명령 실행. 출력은 메모리로만 받고, 실패하면 예외 이름만 알린다(원문은 출력·기록하지 않음)."""

    def __init__(self, env):
        self.env = env

    def __call__(self, command, check=True, stdin=None):
        result = subprocess.run(command, env=self.env, input=stdin, capture_output=True, text=True)
        if check and result.returncode:
            raise SafeError(f"{command[0]} {' '.join(command[1:3])} 실패{exception_name(result.stderr)}"
                            "(원문은 값·ARN이 있을 수 있어 출력하지 않음).")
        return result


def aws(run, profile, *args, check=True, stdin=None):
    return run(["aws", *args, "--profile", profile, "--region", REGION, "--output", "json"], check=check, stdin=stdin)


def check_account(run, profile, expected):
    identity = json.loads(aws(run, profile, "sts", "get-caller-identity").stdout)
    if identity.get("Account") != expected:
        raise SafeError("승인된 AWS 계정이 아닙니다(값은 출력하지 않음). 프로필·SSO 로그인을 확인하세요.")


def check_cli_history(run, profile):
    """AWS CLI history가 켜져 있으면 요청·응답 본문(비밀값)이 로컬 기록에 남는다. 켜져 있으면 멈춘다."""
    result = run(["aws", "configure", "get", "cli_history", "--profile", profile], check=False)
    if (result.stdout or "").strip().lower() == "enabled":
        raise SafeError("AWS CLI history(cli_history=enabled)가 켜져 있어 비밀값이 로컬 기록에 남습니다. 끄고 다시 실행하세요.")


def describe(run, profile):
    """없으면 None, 있으면 VersionIdsToStages. 삭제 예약·권한·연결 오류는 '없음'으로 보지 않고 멈춘다."""
    result = aws(run, profile, "secretsmanager", "describe-secret", "--secret-id", NAME, check=False)
    if result.returncode:
        if "ResourceNotFoundException" in result.stderr:
            return None
        raise SafeError(f"{NAME} 확인 실패{exception_name(result.stderr)}. 권한·SSO 로그인을 확인하세요(없음으로 보지 않음).")
    found = json.loads(result.stdout)
    if found.get("DeletedDate"):
        raise SafeError(f"{NAME}가 삭제 예약 상태입니다. 새로 만들지 않습니다. 복구(restore-secret) 또는 완전 삭제를 먼저 정하세요.")
    return found.get("VersionIdsToStages") or {}


def remote_state(run, profile):
    """'absent' | 'present'."""
    return "absent" if describe(run, profile) is None else "present"


def random_password(run, profile):
    out = aws(run, profile, "secretsmanager", "get-random-password", "--password-length", str(PASSWORD_LENGTH),
              "--exclude-punctuation", "--require-each-included-type").stdout
    value = json.loads(out).get("RandomPassword", "")
    if not re.fullmatch(r"[A-Za-z0-9]{%d}" % PASSWORD_LENGTH, value):
        raise SafeError("get-random-password 결과 형식이 예상과 다릅니다(값은 출력하지 않음).")
    return value


def jwt_pair(run, workdir):
    """0700 임시 폴더에서 RSA 2048 키 쌍(PKCS#8 개인키, SPKI 공개키)을 만들어 읽고 파일을 지운다."""
    private, public = os.path.join(workdir, "jwt-private.pem"), os.path.join(workdir, "jwt-public.pem")
    try:
        run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private])
        run(["openssl", "pkey", "-in", private, "-pubout", "-out", public])
        with open(private) as f:
            private_pem = f.read()
        with open(public) as f:
            public_pem = f.read()
    finally:
        for path in (private, public):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    if not (private_pem.startswith("-----BEGIN PRIVATE KEY-----") and public_pem.startswith("-----BEGIN PUBLIC KEY-----")):
        raise SafeError("JWT 키 형식이 예상과 다릅니다(값은 출력하지 않음).")
    return private_pem, public_pem


def build_values(run, profile, workdir):
    values = {prop: random_password(run, profile) for prop in RANDOM_PROPERTIES}
    if len(set(values.values())) != len(values):
        raise SafeError("무작위 값이 서로 겹칩니다. 다시 실행하세요(값은 출력하지 않음).")
    values["JWT_PRIVATE_KEY"], values["JWT_PUBLIC_KEY"] = jwt_pair(run, workdir)
    values.update(USERNAMES)
    if set(values) != PROPERTIES:
        raise SafeError("묶음 속성 목록이 예상과 다릅니다.")
    return values


def create(run, profile, values):
    """만들면 True. 응답만 잃었지만 이번 실행의 버전(ClientRequestToken = 버전 ID)이 저장된 것을 확인해도 True."""
    payload = json.dumps(values)
    # 이번 쓰기의 표시(비밀 아님). 응답을 잃었을 때 저장된 버전이 이번 실행의 것인지 가려낸다.
    token = str(uuid.uuid4())
    try:
        aws(run, profile, "secretsmanager", "create-secret", "--name", NAME, "--description", DESCRIPTION,
            "--client-request-token", token, "--secret-string", "file:///dev/stdin", "--tags", *TAGS, stdin=payload)
        return True
    except SafeError as error:
        # 응답만 잃고 실제로는 만들어졌을 수 있다. 다시 확인해 안내를 나눈다(값은 출력하지 않음).
        try:
            versions = describe(run, profile)
        except SafeError:
            raise SafeError(f"{error} {NAME} 생성 여부를 확인하지 못했습니다. docs/eks-secrets.md 'prod 시드 실패 복구'를 따르세요.") from None
        if versions is None:
            raise SafeError(f"{error} {NAME}는 만들어지지 않았습니다. 원인을 고친 뒤 그대로 다시 실행하면 됩니다.") from None
        if list(versions) == [token] and "AWSCURRENT" in versions[token]:
            print(f"참고: 생성 응답은 잃었지만 이번 실행의 버전이 {NAME}에 저장된 것을 확인했습니다.", file=sys.stderr)
            return True
        raise SafeError(f"{error} 그런데 {NAME}가 있고 이번 실행의 버전이 아닙니다(동시에 다른 실행이 만든 것). "
                        "이번 값은 버렸습니다. docs/eks-secrets.md 'prod 시드 실패 복구'를 따르세요.") from None
    finally:
        payload = None


def seed(run, profile, expected_account, action, workdir):
    check_cli_history(run, profile)
    check_account(run, profile, expected_account)
    if remote_state(run, profile) == "present":
        raise SafeError(f"{NAME}가 이미 있습니다. 아무것도 바꾸지 않았습니다(덮어쓰기·교체는 이 도구가 하지 않음).")
    if action == "check":
        print(f"{NAME}: 없음 → create로 만들 수 있습니다(변경 없음).")
        return
    values = build_values(run, profile, workdir)
    try:
        create(run, profile, values)
    finally:
        values.clear()
    print(f"{NAME}: 속성 {len(PROPERTIES)}개 생성(값은 출력하지 않음).")


def main(argv=None, runner=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Seed ureka/eks/prod/app with generated values (never printed).")
    parser.add_argument("action", choices=("check", "create"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--confirm-env")
    args = parser.parse_args(argv)
    workdir = None
    try:
        if args.action == "create" and args.confirm_env != "prod":
            raise SafeError("실제 생성은 --confirm-env prod를 명시해야 합니다.")
        expected = os.environ.get("UREKA_EXPECTED_ACCOUNT_ID", "")
        if not re.fullmatch(r"[0-9]{12}", expected):
            raise SafeError("환경 변수 UREKA_EXPECTED_ACCOUNT_ID에 승인 계정 ID(12자리)를 넣어 주세요(값은 출력하지 않음).")
        for tool in ("aws", "openssl") if runner is None else ():  # 시험은 가짜 실행기를 넘긴다
            if not shutil.which(tool):
                raise SafeError(f"{tool}가 필요합니다.")
        run = runner or Runner(clean_env(args.profile))
        workdir = tempfile.mkdtemp(prefix="eks-prod-seed-")  # 0700
        seed(run, args.profile, expected, args.action, workdir)
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError):
        print("중단: 조회 결과 형식이 예상과 다릅니다(값은 출력하지 않음).", file=sys.stderr)
        return 1
    finally:
        if workdir:
            shutil.rmtree(workdir, ignore_errors=True)
    if args.action == "create":
        print("완료. 다음: prod DB bootstrap(scripts/eks/bootstrap_prod_db.py), 그 뒤 비밀 앱 등록(docs/eks-secrets.md).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
