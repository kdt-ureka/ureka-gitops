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


def secret_state(secret_id, profile, region):
    """있음/없음만 판단한다. 권한·연결 오류는 '없음'으로 보지 않고 멈춘다."""
    r = subprocess.run(["aws", "secretsmanager", "describe-secret", "--secret-id", secret_id,
                        "--profile", profile, "--region", region, "--output", "json"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        return "exists"
    if "ResourceNotFoundException" in r.stderr:
        return "absent"
    raise SystemExit("중단: 비밀 존재 여부를 확인하지 못했습니다(권한·연결 확인). 키를 만들지 않았습니다.")


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
    if secret_state(a.secret_id, a.profile, a.region) == "exists":
        raise SystemExit("중단: 같은 이름의 비밀이 이미 있습니다. 덮어쓰지 않습니다.")

    key = aws(["iam", "create-access-key", "--user-name", a.user_name], a.profile, a.region)["AccessKey"]
    try:
        value = json.dumps({"MAIL_USERNAME": key["AccessKeyId"],
                            "MAIL_PASSWORD": smtp_password(key["SecretAccessKey"], a.region)})
        aws(["secretsmanager", "create-secret", "--name", a.secret_id,
             "--description", "SES SMTP 자격(prod auth 메일). 값은 사람이 다루지 않는다.",
             "--secret-string", "file:///dev/stdin"], a.profile, a.region, stdin=value)
    except BaseException:
        # 저장은 됐는데 응답만 잃은 경우 키를 지우면 비밀이 쓸모없어진다. 확실히 없을 때만 지운다.
        try:
            state = secret_state(a.secret_id, a.profile, a.region)
        except SystemExit:
            state = "unknown"
        if state == "absent":
            aws(["iam", "delete-access-key", "--user-name", a.user_name, "--access-key-id", key["AccessKeyId"]],
                a.profile, a.region)
            print("비밀 저장 실패: 방금 만든 접근 키를 지웠습니다.", file=sys.stderr)
        else:
            print(f"비밀 저장 결과가 불확실합니다(상태: {state}). 키를 지우지 않았습니다. "
                  f"{a.secret_id} 존재와 {a.user_name}의 키 개수를 확인한 뒤 정리하세요.", file=sys.stderr)
        raise
    finally:
        key.clear()
    print(f"완료: {a.secret_id} 생성(값 출력 없음). 접근 키 1개를 {a.user_name}에 만들었습니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
