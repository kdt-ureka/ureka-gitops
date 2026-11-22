#!/usr/bin/env python3
"""Register the EKS root Application (#43) with the approved account's ECR registry injected.

The registry contains the account ID, so it never goes to Git, any argv (this tool's or kubectl's), or the
screen: the approved ID is read from UREKA_EXPECTED_ACCOUNT_ID, independently compared with STS, substituted
into argocd/eks/root-app.yaml in memory and passed to kubectl on standard input (same as register_secrets_app.py).
Raw output of failed preflight commands is kept only in the local 0600 .local/eks/last-error.log; do not share it.
check: verify account/cluster/context/Argo CD/Rollouts and server dry-run (no cluster change).
apply: same checks, then server-side apply of the root Application only (Argo CD creates the rest).
"""
import argparse
import json
import os
import re
import subprocess
import sys

from operate import Operator, SafeError, ROOT
from bootstrap_argocd import verify_destination

MANIFEST = ROOT / "argocd/eks/root-app.yaml"
REGION = "ap-northeast-2"
BLANK = '        - name: ecrRegistry\n          value: ""\n'
# Root creates AppProjects/Applications; auth is a Rollout, so the controller CRD must already exist.
CRDS = ("applications.argoproj.io", "appprojects.argoproj.io", "rollouts.argoproj.io")


def inject_registry(source, account):
    if not re.fullmatch(r"[0-9]{12}", account or ""):
        raise SafeError("승인 계정 ID 형식(12자리)이 아닙니다(값은 출력하지 않음).")
    if source.count(BLANK) != 1:
        raise SafeError("root 앱 파일의 ecrRegistry 빈칸을 찾지 못했습니다(Git에 값이 들어갔는지 확인).")
    registry = f"{account}.dkr.ecr.{REGION}.amazonaws.com"
    return source.replace(BLANK, f'        - name: ecrRegistry\n          value: "{registry}"\n')


class Register(Operator):
    def k(self, *args):
        return ["kubectl", "--context", self.args.context, *args]

    def exists(self, *args):
        result = subprocess.run(self.k("get", *args, "-o", "name"), cwd=ROOT, env=self.env,
                                capture_output=True, text=True)
        if result.returncode == 0:
            return True
        if "(NotFound)" in result.stderr:
            return False
        raise SafeError("클러스터 조회 실패(권한·연결). 없음으로 보지 않고 멈춥니다.")

    def preflight(self):
        identity = self.identity()
        cluster = self.aws("eks", "describe-cluster", "--name", self.args.cluster_name)["cluster"]
        config = json.loads(self.run(self.k("config", "view", "--minify", "-o", "json")))
        verify_destination(cluster, config, identity["Account"], self.args.context)
        for crd in CRDS:
            if not self.exists("crd", crd):
                raise SafeError(f"{crd}가 없습니다. Argo CD 설치와 argocd/eks/argo-rollouts-app.yaml Sync를 먼저 하세요.")
        return inject_registry(MANIFEST.read_text(), identity["Account"])

    def execute(self):
        if self.args.action == "apply" and self.args.confirm_cluster != self.args.cluster_name:
            raise SafeError("실제 등록은 --confirm-cluster에 클러스터 이름을 명시해야 합니다.")
        manifest = self.preflight()
        dry = ["--dry-run=server"] if self.args.action == "check" else []
        result = subprocess.run(self.k("apply", "--server-side", "--field-manager=ureka-eks-root-register",
                                       *dry, "-f", "-"),
                                cwd=ROOT, env=self.env, input=manifest, capture_output=True, text=True)
        manifest = None
        if result.returncode:
            # kubectl output may echo the manifest (registry with account ID); never print it.
            raise SafeError("root 앱 등록 실패. 출력에 계정 ID가 있을 수 있어 표시하지 않습니다.")
        if self.args.action == "check":
            print("확인 완료(서버 dry-run, 변경 없음): ureka-eks-root")
        else:
            print("등록 완료: ureka-eks-root. Argo CD에서 dev 앱 Synced·Healthy, prod 앱 OutOfSync(수동 Sync 대기)를 확인하세요.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Register EKS root Application; apply changes Argo CD.")
    parser.add_argument("action", choices=("check", "apply"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--cluster-name", default="ureka-eks")
    parser.add_argument("--context", default="ureka-eks")
    parser.add_argument("--confirm-cluster")
    args = parser.parse_args()
    try:
        # Not an argument: argv is visible to other local processes and shell history.
        args.expected_account_id = os.environ.get("UREKA_EXPECTED_ACCOUNT_ID", "")
        if not re.fullmatch(r"[0-9]{12}", args.expected_account_id):
            raise SafeError("환경 변수 UREKA_EXPECTED_ACCOUNT_ID에 승인 계정 ID(12자리)를 넣어 주세요(값은 출력하지 않음).")
        Register(args).execute()
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, IndexError):
        print("중단: 접속·설정 결과를 확인해 주세요. 비공개 로그는 공유하지 마세요.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
