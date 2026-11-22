#!/usr/bin/env python3
"""SES SMTP 자격을 만들어 Secrets Manager에 바로 넣는다. 값은 화면·인자·파일에 남기지 않는다.

순서: 계정 확인 → IAM 사용자에 기존 키가 없는지 확인 → 접근 키 생성(메모리) →
SMTP 비밀번호 계산(AWS 공식 알고리즘) → Secrets Manager에 새 비밀 생성(표준 입력) →
실패하면 방금 만든 키를 지운다. 이미 비밀·키가 있으면 덮어쓰지 않고 멈춘다.
"""
import argparse
import base64
import hashlib
import hmac
import json
import subprocess
import sys

DATE, SERVICE, TERMINAL, MESSAGE, VERSION = "11111111", "ses", "aws4_request", "SendRawEmail", 0x04


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def smtp_password(secret_access_key: str, region: str) -> str:
    """https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html#smtp-credentials-convert"""
    sig = _sign(("AWS4" + secret_access_key).encode("utf-8"), DATE)
    for part in (region, SERVICE, TERMINAL, MESSAGE):
        sig = _sign(sig, part)
    return base64.b64encode(bytes([VERSION]) + sig).decode("utf-8")


def aws(args, profile, region, stdin=None):
    cmd = ["aws", *args, "--profile", profile, "--region", region, "--output", "json"]
    r = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if r.returncode:
        # stderr에 값이 섞일 수 있어 그대로 보여 주지 않는다.
        raise SystemExit(f"중단: aws {args[0]} {args[1]} 실패(종료 코드 {r.returncode}).")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--profile", required=True)
    p.add_argument("--expected-account-id", required=True)
    p.add_argument("--user-name", default="ureka-ses-smtp")
    p.add_argument("--secret-id", default="ureka/eks/prod/ses-smtp")
    p.add_argument("--region", default="ap-northeast-2")
    a = p.parse_args()

    if aws(["sts", "get-caller-identity"], a.profile, a.region)["Account"] != a.expected_account_id:
        raise SystemExit("중단: 승인된 AWS 계정이 아닙니다.")
    if aws(["iam", "list-access-keys", "--user-name", a.user_name], a.profile, a.region)["AccessKeyMetadata"]:
        raise SystemExit("중단: 이 사용자에 이미 접근 키가 있습니다. 교체는 별도 절차로 합니다.")
    exists = subprocess.run(["aws", "secretsmanager", "describe-secret", "--secret-id", a.secret_id,
                             "--profile", a.profile, "--region", a.region],
                            capture_output=True, text=True).returncode == 0
    if exists:
        raise SystemExit("중단: 같은 이름의 비밀이 이미 있습니다. 덮어쓰지 않습니다.")

    key = aws(["iam", "create-access-key", "--user-name", a.user_name], a.profile, a.region)["AccessKey"]
    try:
        value = json.dumps({"MAIL_USERNAME": key["AccessKeyId"],
                            "MAIL_PASSWORD": smtp_password(key["SecretAccessKey"], a.region)})
        aws(["secretsmanager", "create-secret", "--name", a.secret_id,
             "--description", "SES SMTP 자격(prod auth 메일). 값은 사람이 다루지 않는다.",
             "--secret-string", "file:///dev/stdin"], a.profile, a.region, stdin=value)
    except BaseException:
        aws(["iam", "delete-access-key", "--user-name", a.user_name, "--access-key-id", key["AccessKeyId"]],
            a.profile, a.region)
        raise
    finally:
        key.clear()
    print(f"완료: {a.secret_id} 생성(값 출력 없음). 접근 키 1개를 {a.user_name}에 만들었습니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
