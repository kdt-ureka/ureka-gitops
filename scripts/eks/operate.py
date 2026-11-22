#!/usr/bin/env python3
"""Local EKS operator. AWS mutations happen only in the explicit apply command."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
STACK = ROOT / "infra/environments/eks"
ARTIFACTS = ROOT / ".local/eks"
MAX_AGE = 3600


class SafeError(ValueError):
    """A message authored here, safe to show without private command output."""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest():
    # Includes untracked configuration/override files; excludes provider cache and saved plans.
    paths = sorted(STACK.glob("*.tf")) + sorted(STACK.glob("*.tf.json"))
    paths += sorted(STACK.glob("*.tfvars")) + sorted(STACK.glob("*.tfvars.json"))
    paths += [STACK / "backend.hcl", STACK / ".terraform.lock.hcl", Path(__file__).resolve()]
    return hashlib.sha256("\n".join(str(p.relative_to(ROOT)) + ":" + digest(p)
                                    for p in paths).encode()).hexdigest()


def checked_review(review, token, source, plan_hash, account, now):
    if token != hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest():
        raise SafeError("검토 확인값이 다릅니다.")
    if review["source"] != source or review["plan_sha256"] != plan_hash:
        raise SafeError("코드·설정 또는 plan이 바뀌었습니다. 새 plan을 검토해 주세요.")
    if review["account"] != account:
        raise SafeError("plan을 만든 AWS 계정과 다릅니다.")
    if not 0 <= now - review["created"] <= MAX_AGE:
        raise SafeError("plan 유효 시간(1시간)이 지났습니다. 새 plan이 필요합니다.")


def summarize(plan, destroy):
    if plan.get("errored") or plan.get("complete") is False:
        raise SafeError("완전한 plan이 아닙니다.")
    changes = plan.get("resource_changes", [])
    if not destroy and any("delete" in c["change"]["actions"] for c in changes):
        raise SafeError("생성 계획에 삭제·교체가 있습니다. 별도 검토가 필요합니다.")
    if destroy and any("create" in c["change"]["actions"] or "update" in c["change"]["actions"]
                       for c in changes):
        raise SafeError("삭제 계획에 생성·변경이 섞여 있습니다.")
    return {kind: sum(kind in c["change"]["actions"] for c in changes)
            for kind in ("create", "update", "delete")}


class Operator:
    def __init__(self, args):
        self.args = args
        if any(k.startswith(("TF_VAR_", "TF_CLI_ARGS")) or k in ("TF_DATA_DIR", "TF_PLUGIN_CACHE_DIR")
               for k in os.environ):
            raise SafeError("TF_VAR/TF_CLI_ARGS/TF_DATA_DIR/TF_PLUGIN_CACHE_DIR 환경 변수를 해제해 주세요.")
        if os.environ.get("TF_WORKSPACE", "default") != "default":
            raise SafeError("default workspace만 지원합니다.")
        self.env = dict(os.environ, AWS_PROFILE=args.profile, AWS_DEFAULT_PROFILE=args.profile,
                        AWS_REGION="ap-northeast-2", AWS_DEFAULT_REGION="ap-northeast-2",
                        TF_INPUT="0", TF_IN_AUTOMATION="1", AWS_PAGER="")
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                     "AWS_SECURITY_TOKEN", "AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_STS",
                     "AWS_ENDPOINT_URL_EKS", "AWS_ENDPOINT_URL_EC2", "TF_CLI_CONFIG_FILE"):
            self.env.pop(name, None)
        for name in list(self.env):
            if name.startswith(("AWS_ENDPOINT_URL", "AWS_CONTAINER_CREDENTIALS", "TF_LOG")) or name in (
                    "AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME", "AWS_WEB_IDENTITY_TOKEN_FILE"):
                self.env.pop(name, None)
        ARTIFACTS.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(ARTIFACTS, 0o700)

    def run(self, command):
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, text=True)
        if result.returncode:
            path = ARTIFACTS / "last-error.log"
            path.write_text(result.stdout + result.stderr)
            os.chmod(path, 0o600)
            raise SafeError("실행 실패. 로컬 .local/eks/last-error.log를 확인해 주세요(공유 금지).")
        return result.stdout

    def aws(self, *args):
        return json.loads(self.run(["aws", *args, "--profile", self.args.profile,
                                    "--region", "ap-northeast-2", "--output", "json"]))

    def identity(self):
        identity = self.aws("sts", "get-caller-identity")
        if identity["Account"] != self.args.expected_account_id:
            raise SafeError("승인된 AWS 계정과 다릅니다.")
        return identity

    def run_live(self, command, log_path):
        """Write child output straight to a private file; only heartbeat reaches the console."""
        print("EKS 생성·삭제는 10~20분 이상 걸릴 수 있습니다. 완료 전 임의로 중단하지 마세요.", flush=True)
        started = time.monotonic()
        with log_path.open("wb") as log:
            os.fchmod(log.fileno(), 0o600)
            with subprocess.Popen(command, cwd=ROOT, env=self.env, stdout=log,
                                  stderr=subprocess.STDOUT) as process:
                while True:
                    try:
                        result = process.wait(timeout=30)
                        break
                    except subprocess.TimeoutExpired:
                        print(f"진행 중… {int(time.monotonic() - started)}초 경과. 상세 로그는 로컬 apply.log에 기록 중입니다.", flush=True)
                    except KeyboardInterrupt:
                        # The foreground process group already received SIGINT. Do not send a second
                        # signal: Terraform uses it to force exit rather than shut down gracefully.
                        print("중단 요청을 받았습니다. Terraform 종료를 확인 중입니다. 추가 중단·재실행은 하지 마세요.", flush=True)
        if result:
            for target in (log_path.with_name("apply-error.log"), ARTIFACTS / "last-error.log"):
                with log_path.open("rb") as source, target.open("wb") as destination:
                    os.fchmod(destination.fileno(), 0o600)
                    shutil.copyfileobj(source, destination)
            raise SafeError("적용 실패. 해당 plan 폴더의 apply.log·apply-error.log를 로컬에서 확인해 주세요.")
        return ""

    def tf(self, *args, log_path=None):
        print("Terraform 단계:", args[0], flush=True)
        command = ["terraform", "-chdir=" + str(STACK), *args]
        return self.run_live(command, log_path) if log_path is not None else self.run(command)

    def init(self):
        for name in ("backend.hcl", "terraform.tfvars"):
            if not (STACK / name).is_file():
                raise SafeError("eks의 backend.hcl·terraform.tfvars를 먼저 준비해 주세요.")
        self.tf("init", "-input=false", "-lockfile=readonly", "-reconfigure",
                "-backend-config=backend.hcl")
        if self.tf("workspace", "show").strip() != "default":
            raise SafeError("default workspace만 지원합니다.")

    def cleanup_gate(self):
        outputs = json.loads(self.tf("output", "-json"))
        if not all(outputs.get(key, {}).get("value") for key in ("cluster_name", "node_security_group_id")):
            raise SafeError("EKS outputs가 없습니다. 부분 적용 가능성이 있으므로 status·AWS 콘솔에서 남은 자원을 확인하고 운영 문서의 부분 적용 복구 절차를 따라 주세요.")
        name = outputs["cluster_name"]["value"]
        if self.args.confirm_cleanup != name:
            raise SafeError("앱·LB·PVC 정리 후 --confirm-cleanup에 클러스터 이름을 입력해 주세요.")
        node_sg = outputs["node_security_group_id"]["value"]
        cluster = self.aws("eks", "describe-cluster", "--name", name)["cluster"]
        cluster_sg = cluster["resourcesVpcConfig"]["clusterSecurityGroupId"]
        groups = self.aws("ec2", "describe-security-groups", "--filters",
                          "Name=ip-permission.group-id,Values=" + node_sg)["SecurityGroups"]
        if any(g["GroupId"] not in (node_sg, cluster_sg) for g in groups):
            raise SafeError("외부 SG의 인바운드 참조가 남았습니다. data 등에서 참조 제거·적용이 먼저입니다.")
        self.alb_gate(name, cluster["resourcesVpcConfig"]["vpcId"])

    def alb_gate(self, name, vpc_id):
        # 컨트롤러가 만든 ALB가 남은 채 destroy하면 WAF 삭제에서 멈추고, 클러스터가 먼저 지워지면 관리자 없는 ALB가 과금된다.
        arns = [lb["LoadBalancerArn"] for lb in self.aws("elbv2", "describe-load-balancers")["LoadBalancers"]
                if lb.get("VpcId") == vpc_id]
        for start in range(0, len(arns), 20):
            described = self.aws("elbv2", "describe-tags", "--resource-arns", *arns[start:start + 20])
            for item in described["TagDescriptions"]:
                if any(t["Key"] == "elbv2.k8s.aws/cluster" and t["Value"] == name for t in item.get("Tags", [])):
                    raise SafeError("이 클러스터 컨트롤러가 만든 ALB가 남아 있습니다. 공개 Ingress Application을 먼저 지우고 "
                                    "ALB가 사라진 것을 확인해 주세요(docs/eks-public.md 끄기 순서).")

    def plan(self, destroy=False):
        identity = self.identity()
        self.init()
        if destroy:
            self.cleanup_gate()
        # Separate directories preserve previous evidence and partial-failure plans.
        import tempfile
        folder = Path(tempfile.mkdtemp(prefix="review-", dir=ARTIFACTS))
        plan_path = folder / "saved.tfplan"
        self.tf("validate")
        source = source_digest()
        command = ["plan", "-input=false", "-lock-timeout=60s", "-out=" + str(plan_path)]
        if destroy:
            command.append("-destroy")
        log = self.tf(*command)
        (folder / "plan.log").write_text(log)
        parsed = json.loads(self.tf("show", "-json", str(plan_path)))
        variables = parsed.get("variables", {})
        if variables.get("allowed_account_ids", {}).get("value") != [identity["Account"]]:
            raise SafeError("terraform.tfvars의 허용 계정은 현재 승인 계정 하나만 지정해 주세요.")
        if variables.get("aws_region", {}).get("value") != "ap-northeast-2":
            raise SafeError("현재 운영 도구는 서울 리전만 지원합니다.")
        counts = summarize(parsed, destroy)
        if source != source_digest():
            raise SafeError("plan 도중 코드·설정이 바뀌었습니다. 새 plan을 만들어 주세요.")
        review = dict(source=source, plan_sha256=digest(plan_path),
                      account=identity["Account"], principal=identity["Arn"],
                      created=time.time(), destroy=destroy, counts=counts)
        (folder / "review.json").write_text(json.dumps(review, sort_keys=True))
        for path in folder.iterdir():
            os.chmod(path, 0o600)
        print("plan 저장 위치:", folder.relative_to(ROOT))
        print("예정:", counts)
        print("확인값:", hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest())
        print("plan.log를 로컬에서 확인해 주세요. apply는 별도 명령입니다.")

    def apply(self):
        folder = Path(self.args.review_dir).resolve()
        if folder.parent != ARTIFACTS.resolve():
            raise SafeError("이 작업 폴더에서 저장한 plan만 적용할 수 있습니다.")
        if (folder / "attempted").exists():
            raise SafeError("적용을 시도한 plan은 재사용할 수 없습니다. 상태 확인 후 새 plan을 만들어 주세요.")
        review = json.loads((folder / "review.json").read_text())
        identity = self.identity()
        self.init()
        checked_review(review, self.args.confirm, source_digest(),
                       digest(folder / "saved.tfplan"), identity["Account"], time.time())
        if review["principal"] != identity["Arn"]:
            raise SafeError("plan을 만든 로그인 주체와 다릅니다. 새 plan이 필요합니다.")
        # A worktree/branch name is irrelevant; executed code must match merged main.
        self.run(["git", "fetch", "origin", "main"])
        scope = ["infra/environments/eks", "infra/environments/data", "infra/modules/network",
                 "scripts/eks", "tests/eks", ".github/workflows/terraform.yml", ".gitignore", "docs/eks.md"]
        if self.run(["git", "diff", "--name-only", "origin/main", "--", *scope]).strip():
            raise SafeError("EKS 관련 코드가 최신 main과 다릅니다. 병합·갱신 후 새 plan을 검토해 주세요.")
        if self.run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip():
            raise SafeError("커밋하지 않은 변경이 있습니다. 적용할 수 없습니다.")
        if review["destroy"]:
            self.cleanup_gate()
        try:
            with (folder / "attempted").open("x") as marker:
                marker.write(str(time.time()))
        except FileExistsError:
            raise SafeError("다른 실행이 이미 적용을 시도한 plan입니다. 완료 상태 확인 후 새 plan을 만들어 주세요.") from None
        started = time.time()
        success = False
        try:
            self.tf("apply", "-input=false", "-lock-timeout=60s", str(folder / "saved.tfplan"),
                    log_path=folder / "apply.log")
            success = True
        finally:
            finished = time.time()
            (folder / "result.json").write_text(json.dumps(dict(
                started=started, finished=finished, elapsed_seconds=finished - started,
                terraform_success=success, destroy=review["destroy"])))
            os.chmod(folder / "result.json", 0o600)
            print("적용 기록:", folder.relative_to(ROOT), "실패 시 재실행하지 말고 상태를 확인해 주세요.")
        print("완료. 실제 동작·잔존 자원은 status와 운영 절차로 별도 확인해 주세요.")

    def status(self):
        self.identity()
        self.init()
        outputs = json.loads(self.tf("output", "-json"))
        if "cluster_name" not in outputs:
            print("EKS 출력이 없습니다. 미생성·삭제 완료·부분 적용 가능성이 있습니다. AWS 콘솔에서 남은 자원을 확인한 뒤 운영 문서의 부분 적용 복구 절차를 따라 주세요.")
            return
        name = outputs["cluster_name"]["value"]
        cluster = self.aws("eks", "describe-cluster", "--name", name)["cluster"]
        print("cluster:", cluster["status"], "version:", cluster["version"])
        for node in self.aws("eks", "list-nodegroups", "--cluster-name", name)["nodegroups"]:
            ng = self.aws("eks", "describe-nodegroup", "--cluster-name", name,
                          "--nodegroup-name", node)["nodegroup"]
            print("nodegroup:", node, ng["status"])
        print("ACTIVE는 Pod Ready 확인이 아닙니다. kubectl 확인이 별도로 필요합니다.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="EKS plan/apply/status operator; apply mutates AWS.")
    parser.add_argument("action", choices=("plan", "destroy-plan", "apply", "status"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--expected-account-id", required=True)
    parser.add_argument("--review-dir")
    parser.add_argument("--confirm")
    parser.add_argument("--confirm-cleanup")
    args = parser.parse_args()
    if args.action == "apply" and (not args.review_dir or not args.confirm):
        parser.error("apply에는 --review-dir와 --confirm이 필요합니다.")
    try:
        op = Operator(args)
        if args.action in ("plan", "destroy-plan"):
            op.plan(args.action == "destroy-plan")
        else:
            getattr(op, args.action)()
    except SafeError as error:
        print("중단:", error, file=sys.stderr)
        return 1
    except (ValueError, KeyError, OSError):
        # Do not leak account IDs, endpoints, credentials, or configuration in tracebacks.
        print("중단: 설정·실행 결과를 확인해 주세요. 오류 로그는 로컬에서 확인해 주세요.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
