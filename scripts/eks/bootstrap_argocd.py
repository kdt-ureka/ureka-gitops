#!/usr/bin/env python3
"""Install the pinned Argo CD control plane only. Application/Secret wiring is separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

from operate import Operator, SafeError, ROOT, ARTIFACTS

VERSION = "v3.6.0"
SHA256 = "c1d7ec243fa63ce675d71e564775ae42bf11608d35436d5c5951365b6c86fa6a"
URL = f"https://raw.githubusercontent.com/argoproj/argo-cd/{VERSION}/manifests/install.yaml"
NAMESPACE = ROOT / "argocd/eks/namespace.yaml"


def verify_manifest(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SafeError("Argo CD 설치 파일 체크섬이 다릅니다. 설치하지 않습니다.")


def verify_destination(cluster, config, account, expected_context):
    if cluster["arn"].split(":")[4] != account or cluster["status"] != "ACTIVE":
        raise SafeError("승인 계정의 ACTIVE EKS가 아닙니다.")
    if config.get("current-context") != expected_context:
        raise SafeError("조회한 kubectl current-context가 지정한 대상과 다릅니다.")
    context = config["contexts"][0]["context"]["cluster"]
    servers = [c["cluster"]["server"] for c in config["clusters"] if c["name"] == context]
    if servers != [cluster["endpoint"]]:
        raise SafeError("kubectl context와 승인된 EKS 접속 주소가 다릅니다.")


class Bootstrap(Operator):
    def k(self, *args):
        return ["kubectl", "--context", self.args.context, *args]

    def preflight(self):
        identity = self.identity()
        cluster = self.aws("eks", "describe-cluster", "--name", self.args.cluster_name)["cluster"]
        config = json.loads(self.run(self.k("config", "view", "--minify", "-o", "json")))
        verify_destination(cluster, config, identity["Account"], self.args.context)
        nodes = json.loads(self.run(self.k("get", "nodes", "-o", "json")))["items"]
        if len(nodes) < 2 or any(not any(c["type"] == "Ready" and c["status"] == "True"
                                       for c in node["status"]["conditions"]) for node in nodes):
            raise SafeError("Ready 노드가 최소 2대 필요합니다.")
        base = ARTIFACTS / "argocd-bootstrap"
        base.mkdir(mode=0o700, exist_ok=True)
        os.chmod(base, 0o700)
        # check may run while install is using an earlier manifest. Every invocation
        # owns its download, Kustomization and rendered file; never rewrite shared inputs.
        folder = Path(tempfile.mkdtemp(prefix="run-", dir=base))
        path = folder / f"install-{VERSION}.yaml"
        # Public, pinned manifest; never use stable/latest or a user-provided URL.
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read()
        verify_manifest(data)
        path.write_bytes(data)
        path.chmod(0o600)
        return self.render_manifest(path)

    def render_manifest(self, path):
        # Patch the complete upstream objects BEFORE SSA. Applying a partial object with
        # the same manager afterwards would relinquish/delete omitted owned fields.
        config = {
            "apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
            "resources": [path.name],
            "patches": [{"patch": json.dumps({
                "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": name},
                "spec": {"replicas": 0}})}
                for name in ("argocd-dex-server", "argocd-notifications-controller")],
        }
        kustomization = path.parent / "kustomization.yaml"
        kustomization.write_text(json.dumps(config))
        kustomization.chmod(0o600)
        rendered = path.parent / "rendered.yaml"
        rendered.write_text(self.run(["kubectl", "kustomize", str(path.parent)]))
        rendered.chmod(0o600)
        return rendered

    def merged_code(self):
        self.run(["git", "fetch", "origin", "main"])
        if self.run(["git", "diff", "--name-only", "origin/main", "--", "scripts/eks", "argocd/eks"]).strip():
            raise SafeError("설치 코드를 리뷰·병합하고 최신 main과 맞춘 뒤 실행해 주세요.")
        if self.run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip():
            raise SafeError("커밋하지 않은 변경이 있어 설치하지 않습니다.")

    def install_step(self, command, path):
        # Private live log, with a heartbeat; kubectl output must not expose private data.
        with path.open("wb") as log:
            os.fchmod(log.fileno(), 0o600)
            with subprocess.Popen(command, cwd=ROOT, env=self.env, stdout=log,
                                  stderr=subprocess.STDOUT) as process:
                while True:
                    try:
                        code = process.wait(timeout=30)
                        break
                    except subprocess.TimeoutExpired:
                        print("Argo CD 설치 진행 중… 임의 중단·중복 실행하지 마세요.", flush=True)
                    except KeyboardInterrupt:
                        print("중단 요청 후 종료 확인 중입니다. 추가 중단·재실행하지 마세요.", flush=True)
        if code:
            raise SafeError("설치 단계 실패. .local/eks/argocd-bootstrap의 단계별 로그를 확인해 주세요.")

    def execute(self):
        if self.args.action == "install":
            if self.args.confirm_cluster != self.args.cluster_name:
                raise SafeError("실제 변경은 --confirm-cluster에 대상 이름을 명시해야 합니다.")
            self.merged_code()
        path = self.preflight()
        print("계정·EKS context·Ready 노드·설치 파일 체크섬 확인 완료.")
        if self.args.action == "check":
            print("확인만 완료. 클러스터 변경 없음.")
            return
        folder = ARTIFACTS / "argocd-bootstrap"
        # Prevent overlapping installs on this PC, without deleting failure evidence.
        lock = folder / "in-progress"
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise SafeError("설치 실행 기록이 남아 있습니다. 실행 중인지 확인하고 복구 절차를 따라 주세요.") from None
        with os.fdopen(fd, "w") as f:
            f.write(str(os.getpid()))
        run_folder = path.parent
        started = time.time()
        success = False
        try:
            steps = [
                ("namespace", self.k("apply", "--server-side", "--field-manager=ureka-eks-bootstrap", "-f", str(NAMESPACE))),
                ("install", self.k("-n", "argocd", "apply", "--server-side", "--field-manager=ureka-eks-bootstrap", "-f", str(path))),
            ]
            for target in ("deployment/argocd-server", "deployment/argocd-repo-server", "statefulset/argocd-application-controller"):
                steps.append((target.split("/")[1], self.k("-n", "argocd", "rollout", "status", target, "--timeout=300s")))
            for name, command in steps:
                print("설치 단계:", name, flush=True)
                self.install_step(command, run_folder / (name + ".log"))
            success = True
        finally:
            result = run_folder / "result.json"
            result.write_text(json.dumps(dict(started=started, finished=time.time(), success=success)))
            result.chmod(0o600)
            # Keep the lock on failure: inspect partial installation before deliberate retry.
            if success:
                lock.unlink()
        print("Argo CD 설치 완료. 앱·Secret·DB 설정은 아직 변경하지 않았습니다.")
        print("설치 기록:", run_folder.relative_to(ROOT))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="EKS Argo CD check/install; install changes Kubernetes resources.")
    parser.add_argument("action", choices=("check", "install"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--expected-account-id", required=True)
    parser.add_argument("--cluster-name", default="ureka-eks")
    parser.add_argument("--context", default="ureka-eks")
    parser.add_argument("--confirm-cluster")
    try:
        Bootstrap(parser.parse_args()).execute()
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, IndexError):
        print("중단: 접속·설정·다운로드 결과를 확인해 주세요. 비공개 로그는 공유하지 마세요.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
