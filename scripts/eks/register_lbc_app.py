#!/usr/bin/env python3
"""Register the AWS Load Balancer Controller Application (#64) and verify the public ALB's WAF.

The account ID never goes to Git, any argv (this tool's or kubectl's), or the screen: the approved ID is read
from UREKA_EXPECTED_ACCOUNT_ID, compared with STS, substituted into the IRSA role ARN placeholder in memory and
passed to kubectl on standard input. Raw output of failed commands is kept only in the local 0600
.local/eks/last-error.log (inherited Operator.run); do not share it.
check:  account/cluster/context, Terraform public resources present, server dry-run (no cluster change).
apply:  same checks, then server-side apply of the Application only (a person then Syncs it in Argo CD).
verify: after the public Ingress Sync, exactly one controller ALB exists, uses the Terraform frontend SG
        ureka-eks-alb-public and is associated with WAF ureka-eks-public. Run before Terraform phase two
        (public_dns_enabled=true) and again before public_access_mode=open. Read-only.
ALB ARNs (they contain the account ID) are sent to the AWS CLI as standard-input JSON, never as arguments.
"""
import argparse
import json
import os
import re
import subprocess
import sys

from operate import Operator, SafeError, ROOT
from bootstrap_argocd import verify_destination

APP = ROOT / "argocd/eks/aws-load-balancer-controller-app.yaml"
PLACEHOLDER = "arn:aws:iam::ACCOUNT_ID_INJECTED_AT_REGISTRATION:role/ureka-eks-aws-load-balancer-controller"
ROLE = "ureka-eks-aws-load-balancer-controller"
WEB_ACL = "ureka-eks-public"
ALB_GROUP = "ureka-prod"
ALB_SG = "ureka-eks-alb-public"


def inject_account(source, account):
    if not re.fullmatch(r"[0-9]{12}", account or ""):
        raise SafeError("승인 계정 ID 형식(12자리)이 아닙니다(값은 출력하지 않음).")
    if source.count(PLACEHOLDER) != 1 or source.count("ACCOUNT_ID_INJECTED_AT_REGISTRATION") != 1:
        raise SafeError("Application 파일의 역할 ARN 자리표시를 정확히 하나 찾지 못했습니다(Git에 값이 들어갔는지 확인).")
    return source.replace(PLACEHOLDER, f"arn:aws:iam::{account}:role/{ROLE}")


def controller_albs(load_balancers, tag_descriptions, cluster, vpc_id):
    in_vpc = {lb["LoadBalancerArn"] for lb in load_balancers if lb.get("VpcId") == vpc_id}
    found = []
    for item in tag_descriptions:
        tags = {t["Key"]: t["Value"] for t in item.get("Tags", [])}
        if item["ResourceArn"] in in_vpc and tags.get("elbv2.k8s.aws/cluster") == cluster \
                and tags.get("ingress.k8s.aws/stack") == ALB_GROUP:
            found.append(item["ResourceArn"])
    return found


class Register(Operator):
    def k(self, *args):
        return ["kubectl", "--context", self.args.context, *args]

    def destination(self):
        identity = self.identity()
        cluster = self.aws("eks", "describe-cluster", "--name", self.args.cluster_name)["cluster"]
        config = json.loads(self.run(self.k("config", "view", "--minify", "-o", "json")))
        verify_destination(cluster, config, identity["Account"], self.args.context)
        return identity, cluster

    def web_acl_names(self):
        return {acl["Name"] for acl in self.aws("wafv2", "list-web-acls", "--scope", "REGIONAL")["WebACLs"]}

    def preflight(self):
        identity, _ = self.destination()
        # public_enabled=true apply 전이면 역할·WAF가 없다. 없는 채로 등록하면 컨트롤러가 ALB를 만들지 못하거나 WAF 없이 만들 수 있다.
        self.aws("iam", "get-role", "--role-name", ROLE)
        if WEB_ACL not in self.web_acl_names():
            raise SafeError("WAF ureka-eks-public이 없습니다. Terraform public_enabled=true apply를 먼저 해 주세요.")
        return inject_account(APP.read_text(), identity["Account"])

    def register(self):
        if self.args.action == "apply" and self.args.confirm_cluster != self.args.cluster_name:
            raise SafeError("실제 등록은 --confirm-cluster에 클러스터 이름을 명시해야 합니다.")
        manifest = self.preflight()
        dry = ["--dry-run=server"] if self.args.action == "check" else []
        result = subprocess.run(self.k("apply", "--server-side", "--field-manager=ureka-eks-lbc-register",
                                       *dry, "-f", "-"),
                                cwd=ROOT, env=self.env, input=manifest, capture_output=True, text=True)
        manifest = None
        if result.returncode:
            # kubectl output may echo the manifest (account ID); never print it.
            raise SafeError("Application 등록 실패. 출력에 계정 ID가 있을 수 있어 표시하지 않습니다.")
        if self.args.action == "check":
            print("확인 완료(서버 dry-run, 변경 없음): aws-load-balancer-controller")
        else:
            print("등록 완료: aws-load-balancer-controller. Argo CD에서 직접 Sync하고 Healthy를 확인하세요.")

    def verify(self):
        _, cluster = self.destination()
        vpc_id = cluster["resourcesVpcConfig"]["vpcId"]
        lbs = self.aws("elbv2", "describe-load-balancers")["LoadBalancers"]
        arns = [lb["LoadBalancerArn"] for lb in lbs if lb.get("VpcId") == vpc_id]
        tags = []
        for start in range(0, len(arns), 20):
            tags += self.aws("elbv2", "describe-tags",
                             payload={"ResourceArns": arns[start:start + 20]})["TagDescriptions"]
        found = controller_albs(lbs, tags, self.args.cluster_name, vpc_id)
        if len(found) != 1:
            raise SafeError(f"prod 공개 ALB가 정확히 하나가 아닙니다({len(found)}개). Ingress 이벤트를 확인해 주세요.")
        groups = self.aws("ec2", "describe-security-groups", "--filters", f"Name=vpc-id,Values={vpc_id}",
                          f"Name=group-name,Values={ALB_SG}")["SecurityGroups"]
        attached = next(lb.get("SecurityGroups", []) for lb in lbs if lb["LoadBalancerArn"] == found[0])
        if len(groups) != 1 or groups[0]["GroupId"] not in attached:
            raise SafeError("공개 ALB에 Terraform 입구 SG(ureka-eks-alb-public)가 붙지 않았습니다. 멈추고 Ingress를 지워 주세요.")
        acl = self.aws("wafv2", "get-web-acl-for-resource", payload={"ResourceArn": found[0]}).get("WebACL") or {}
        if acl.get("Name") != WEB_ACL:
            raise SafeError("공개 ALB에 WAF ureka-eks-public이 연결되지 않았습니다. DNS(2단계)를 진행하지 말고 "
                            "Ingress를 지우거나 컨트롤러 로그를 확인해 주세요.")
        print("확인: prod 공개 ALB 1개, 입구 SG ureka-eks-alb-public, WAF ureka-eks-public 연결됨. "
              "입구 SG의 현재 단계(시험자/open)는 Terraform 변수로 확인하세요.")

    def execute(self):
        if self.args.action == "verify":
            self.verify()
        else:
            self.register()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Register AWS Load Balancer Controller Application / verify public ALB WAF.")
    parser.add_argument("action", choices=("check", "apply", "verify"))
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
