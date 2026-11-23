#!/usr/bin/env python3
"""Register the EKS dev/prod secrets Application (#63) with the approved account ID injected.

The account ID never goes to Git, any argv (this tool's or kubectl's), or the screen: the approved ID is read
from UREKA_EXPECTED_ACCOUNT_ID, independently compared with STS, substituted into the Application manifest in
memory and passed to kubectl on standard input. Raw output of failed preflight commands is kept only in the
local 0600 .local/eks/last-error.log (inherited Operator.run); do not share it.
check: verify account/cluster/context/ESO/namespace and render locally (no cluster change).
apply: same checks, then server-side apply of the Application only (Argo CD syncs the rest).
"""
import argparse
import json
import os
import re
import subprocess
import sys

from operate import Operator, SafeError, ROOT
from bootstrap_argocd import verify_destination

BLANK = '        - name: awsAccountId\n          value: ""\n'
CRDS = ("externalsecrets.external-secrets.io", "secretstores.external-secrets.io")
# Cluster-wide stores would let any namespace borrow a reader; the ESO app does not install them.
FORBIDDEN_CRDS = ("clustersecretstores.external-secrets.io", "clusterexternalsecrets.external-secrets.io")


def manifest_path(env):
    return ROOT / "argocd/eks" / f"secrets-{env}-app.yaml"


def inject_account(source, account):
    if not re.fullmatch(r"[0-9]{12}", account or ""):
        raise SafeError("승인 계정 ID 형식(12자리)이 아닙니다(값은 출력하지 않음).")
    if source.count(BLANK) != 1:
        raise SafeError("Application 파일의 awsAccountId 빈칸을 찾지 못했습니다(Git에 값이 들어갔는지 확인).")
    return source.replace(BLANK, f'        - name: awsAccountId\n          value: "{account}"\n')


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
                raise SafeError("ESO가 설치되지 않았습니다. argocd/eks/external-secrets-app.yaml을 먼저 Sync하세요.")
        for crd in FORBIDDEN_CRDS:
            if self.exists("crd", crd):
                raise SafeError("클러스터 범위 ESO 저장소 CRD가 있습니다. 환경 분리가 깨지므로 멈춥니다.")
        if not self.exists("namespace", self.args.env):
            raise SafeError(f"{self.args.env} 네임스페이스가 없습니다(#62 먼저).")
        source = manifest_path(self.args.env).read_text()
        return inject_account(source, identity["Account"])

    def execute(self):
        if self.args.action == "apply" and self.args.confirm_env != self.args.env:
            raise SafeError("실제 등록은 --confirm-env에 환경 이름을 명시해야 합니다.")
        manifest = self.preflight()
        dry = ["--dry-run=server"] if self.args.action == "check" else []
        result = subprocess.run(self.k("apply", "--server-side", "--field-manager=ureka-eks-secrets-register",
                                       *dry, "-f", "-"),
                                cwd=ROOT, env=self.env, input=manifest, capture_output=True, text=True)
        manifest = None
        if result.returncode:
            # kubectl output may echo the manifest (account ID); never print it.
            raise SafeError("Application 등록 실패. 출력에 계정 ID가 있을 수 있어 표시하지 않습니다.")
        if self.args.action == "check":
            print(f"확인 완료(서버 dry-run, 변경 없음): ureka-eks-secrets-{self.args.env}")
        else:
            print(f"등록 완료: ureka-eks-secrets-{self.args.env}. Argo CD에서 Synced·ExternalSecret Ready를 확인하세요.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Register EKS secrets Application; apply changes Argo CD.")
    parser.add_argument("action", choices=("check", "apply"))
    parser.add_argument("--env", required=True, choices=("dev", "prod"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--cluster-name", default="ureka-eks")
    parser.add_argument("--context", default="ureka-eks")
    parser.add_argument("--confirm-env")
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
