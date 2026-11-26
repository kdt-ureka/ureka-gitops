#!/usr/bin/env python3
"""Checkpoint runner for EKS up/down. No automatic mutation; existing tools own approvals.

Only --execute <the first pending step> permits a single existing mutating tool.
Manual-only checkpoints must be satisfied in live state, never by a --done flag.
All subprocess output is captured, discarded and never copied to lifecycle state/logs.
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import fcntl
import hashlib
import contextlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from operate import ROOT, Operator, SafeError
from bootstrap_argocd import verify_destination


@dataclass(frozen=True)
class Step:
    key: str
    title: str
    hint: str
    tool: tuple = ()


UP = (
    Step('access', '관리 API 허용 IP 확인', '현재 공인 IPv4를 read -s UREKA_CURRENT_IPV4; export UREKA_CURRENT_IPV4 로 입력. 목록과 비교하며 값은 표시하지 않음.'),
    Step('infra', 'EKS 생성·Ready', 'operate.py plan → plan.log 검토 → apply --review-dir … --confirm …; 같은 plan 재사용 금지, 유효 1시간.', ('operate.py', 'plan')),
    Step('data', 'data의 노드 SG 허용', 'EKS output의 node_security_group_id를 본 worktree data tfvars에 반영 → data plan 검토(DB/SG 교체 없음) → apply. 다른 스택 destroy 금지.'),
    Step('context', 'kubeconfig 대상 확인', 'EKS output kubeconfig_hint의 update-kubeconfig 실행(로컬 출력 비공개).'),
    Step('argocd', 'Argo CD 설치', 'bootstrap_argocd.py install --confirm-cluster …', ('bootstrap_argocd.py', 'install')),
    Step('controllers', 'Rollouts·ESO 준비 및 admin 비밀 정리', 'argocd/eks/argo-rollouts-app.yaml·external-secrets-app.yaml 등록 후 직접 Sync. 초기 admin 비밀을 키체인에 저장한 뒤 초기 Secret 삭제.'),
    Step('root', 'root 앱 등록', 'register_root_app.py apply --confirm-cluster …', ('register_root_app.py', 'apply')),
    Step('dev-secrets', 'dev 비밀 복사·복사 스위치 해제', 'data의 eks_dev_secret_copy_enabled=true 계획 검토/apply → EC2 SSM에서 scripts/ec2/copy_eks_dev_secrets.py copy → data 스위치 false 복원·plan 검토/apply. 비밀 직접 출력 금지.'),
    Step('prod-seed', 'prod 비밀 준비', 'seed_prod_secrets.py create --confirm-env prod (기존 비밀은 덮어쓰지 않음).', ('seed_prod_secrets.py', 'create')),
    Step('prod-db', 'prod DB 부트스트랩', 'bootstrap_prod_db.py apply --confirm-env prod; 완료·임시 자원 정리까지 기존 도구가 검사.', ('bootstrap_prod_db.py', 'apply')),
    Step('secrets-dev', 'dev 비밀 앱·ExternalSecret Ready', 'register_secrets_app.py apply --env dev --confirm-env dev', ('register_secrets_app.py', 'apply', '--env', 'dev')),
    Step('secrets-prod', 'prod 비밀 앱·ExternalSecret Ready', 'register_secrets_app.py apply --env prod --confirm-env prod', ('register_secrets_app.py', 'apply', '--env', 'prod')),
    Step('services', 'dev 정상·prod 수동 Sync·auth 승격', 'ExternalSecret Ready 후 prod 앱을 사람이 Sync. 양 환경 auth 카나리를 확인·승격. 모든 서비스 Synced/Healthy 확인.'),
    Step('content', 'prod content 복사', 'copy_prod_content.py apply --confirm-env prod; 기존 prod 데이터가 있으면 --verify-existing로 대조만 수행(재복사 없음).', ('copy_prod_content.py', 'apply')),
    Step('public-infra', '공개 입구 testers 인프라', 'public_enabled=true, public_access_mode=testers, public_dns_enabled=false로 operate.py plan → 검토 → apply. open은 별도 공개 승인.', ('operate.py', 'plan')),
    Step('lbc', 'ALB 컨트롤러 등록·Sync', 'register_lbc_app.py check 후 apply --confirm-cluster …; Argo CD에서 컨트롤러 직접 Sync.', ('register_lbc_app.py', 'apply')),
    Step('ingress', '공개 Ingress 등록·수동 Sync', 'kubectl로 argocd/eks/prod-public-ingress-app.yaml 등록 후 사람이 Sync. ALB 생성 대기.'),
    Step('alb-policy', 'ALB 검증·CIDR 1회 주입·정책 Sync', 'register_lbc_app.py verify 후 --execute alb-policy --confirm-cluster … 로 중복 방지 주입. 그 뒤 prod 정책 앱을 직접 Sync.'),
    Step('targets', 'ALB 대상 healthy 확인', 'prod 정책 앱을 Sync하고 ALB target health를 확인. 실패 시 DNS 단계 금지.'),
    Step('dns', 'DNS 활성화', 'ALB/WAF/대상 검증 후 public_dns_enabled=true로 operate.py plan → 검토 → apply. testers 유지, open은 자동 전환하지 않음.', ('operate.py', 'plan')),
    Step('connections', 'RDS 연결 수 확인', 'CloudWatch DatabaseConnections를 읽음. 통과 수치 기준은 PM과 정한 UREKA_DB_CONNECTION_LIMIT로 입력(임의 기본값 없음).'),
)
DOWN = (
    Step('access', '관리 API 허용 IP 확인', UP[0].hint),
    Step('context', '계정·클러스터·kubeconfig 확인', UP[3].hint),
    Step('ingress-removed', '공개 Ingress 앱·리소스 삭제', '종료 안내 후 공개 Ingress Application을 리소스와 함께 삭제. ALB 정리 전 컨트롤러는 유지.'),
    Step('alb-gone', '클러스터 태그 ALB 0개 확인', '컨트롤러가 ALB를 정리할 때까지 대기. 이 단계 전에는 앱 정리/data SG 해제/destroy로 진행하지 않음.'),
    Step('apps-removed', '업무 앱·LB·PVC 정리', '자동 재생성(root)을 중단하고 dev/prod 업무 앱과 LB·PVC 정리. 보관 데이터는 백업. 컨트롤러는 ALB 삭제 뒤 정리.'),
    Step('data-removed', 'data 노드 SG 참조 해제', 'data tfvars의 eks_node_security_group_ids=[]로 복원 → plan(DB 교체 없음) 검토 → apply.'),
    Step('destroy', 'EKS 전용 destroy', 'operate.py destroy-plan --confirm-cleanup … → 검토 → apply --review-dir … --confirm … --confirm-cleanup …; cleanup_gate 재검사. network/data/shared destroy 금지.', ('operate.py', 'destroy-plan')),
    Step('residue', '잔존 자원 확인', 'NAT/EIP/ENI/EBS 및 공개 입구 WAF/SG/인증서/DNS 잔존을 운영 문서대로 별도 확인. 자동 삭제 금지.'),
)
SERVICES = ('auth', 'chat', 'content', 'ops', 'recommend', 'frontend')
REGION = 'ap-northeast-2'
# Managed addresses in the EKS stack only. New resources require an explicit scope review.
INFRA_RESOURCES = frozenset("""
aws_eip.nat aws_nat_gateway.this aws_route.private_internet
aws_cloudwatch_log_group.cluster aws_eks_cluster.this aws_eks_access_entry.admin
aws_eks_access_policy_association.admin aws_security_group.nodes
aws_vpc_security_group_ingress_rule.nodes_self aws_vpc_security_group_ingress_rule.control_to_nodes
aws_vpc_security_group_ingress_rule.control_https_to_nodes aws_vpc_security_group_ingress_rule.nodes_to_api
aws_vpc_security_group_egress_rule.nodes aws_launch_template.nodes aws_eks_node_group.this
aws_iam_role.cluster aws_iam_role_policy_attachment.cluster aws_iam_role.nodes
aws_iam_role_policy_attachment.nodes aws_iam_openid_connect_provider.this
aws_iam_role.addon aws_iam_role_policy_attachment.addon aws_eks_addon.cni aws_eks_addon.runtime
aws_iam_role.eso_reader aws_iam_role_policy.eso_reader
""".split())
PUBLIC_RESOURCES = frozenset("""
aws_acm_certificate.public aws_route53_record.cert_validation aws_acm_certificate_validation.public
aws_ec2_managed_prefix_list.alb_testers aws_security_group.alb_public
aws_vpc_security_group_ingress_rule.alb_testers aws_vpc_security_group_egress_rule.alb_to_pods
aws_wafv2_ip_set.admin aws_wafv2_web_acl.public aws_iam_role.lbc aws_iam_policy.lbc
aws_iam_role_policy_attachment.lbc aws_iam_role_policy.lbc_waf_lookup
""".split())
DNS_RESOURCES = frozenset(('aws_route53_record.public',))
DESTROY_RESOURCES = INFRA_RESOURCES | PUBLIC_RESOURCES | DNS_RESOURCES | frozenset(('aws_vpc_security_group_ingress_rule.alb_open',))


def check_phase_settings(phase, values):
    if phase == 'destroy':
        return
    expected = {'infra': (False, False), 'public-infra': (True, False), 'dns': (True, True)}
    if (phase not in expected or values.get('mode') != 'testers'
            or (values.get('public'), values.get('dns')) != expected[phase]
            or type(values.get('public')) is not bool or type(values.get('dns')) is not bool):
        raise SafeError('공개/DNS 설정이 현재 단계와 다릅니다. testers·단계별 설정을 확인하세요.')


def check_plan_scope(plan, phase, cluster_name):
    variables = {k: v.get('value') for k, v in plan.get('variables', {}).items()}
    if (variables.get('aws_region') != REGION
            or variables.get('project_name', '') + '-eks' != cluster_name):
        raise SafeError('plan의 리전·클러스터가 지정한 대상과 다릅니다.')
    check_phase_settings(phase, {'mode': variables.get('public_access_mode'),
                               'public': variables.get('public_enabled'), 'dns': variables.get('public_dns_enabled')})
    allowed = {'infra': INFRA_RESOURCES, 'public-infra': PUBLIC_RESOURCES,
               'dns': DNS_RESOURCES, 'destroy': DESTROY_RESOURCES}[phase]
    if plan.get('errored') or plan.get('complete') is False:
        raise SafeError('완전한 plan이 아닙니다.')
    for change in plan.get('resource_changes', []):
        actions = change['change']['actions']
        if actions == ['no-op']:
            continue
        if change.get('mode') == 'data' and actions == ['read']:
            continue
        match = re.fullmatch(r'(aws_[a-z0-9_]+\.[A-Za-z_][A-Za-z_0-9]*)(?:\[(?:[0-9]+|"[^"\\]*")\])?', change.get('address', ''))
        expected_actions = (['delete'],) if phase == 'destroy' else (['create'], ['update'])
        if (change.get('mode') != 'managed' or not match or match[1] not in allowed
                or change.get('type') != match[1].split('.')[0] or actions not in expected_actions):
            raise SafeError('현재 단계에서 허용하지 않은 자원 변경이 있습니다. 새 plan을 검토하세요.')



def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def ready(obj, condition='Ready'):
    return any(c.get('type') == condition and c.get('status') == 'True'
               for c in obj.get('status', {}).get('conditions', []))


def healthy(app):
    s = app.get('status', {})
    return (s.get('sync', {}).get('status') == 'Synced'
            and s.get('health', {}).get('status') == 'Healthy'
            and s.get('operationState', {}).get('phase') not in ('Running', 'Failed', 'Error'))


def cidr_patch(parameters, cidrs):
    """Return an atomic append patch, [] for identical configuration, fail on drift/duplicates."""
    import importlib.util
    path = ROOT / 'scripts/netpol/alb-root-patch.py'
    spec = importlib.util.spec_from_file_location('alb_root_patch', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    additions = module.patch(sorted(cidrs))
    expected = [p['value'] for p in additions]
    actual = [p for p in parameters if p.get('name', '').startswith('networkPolicy.alb.')]
    if actual:
        if len(actual) == len(expected) and {p['name']: p for p in actual} == {p['name']: p for p in expected}:
            return []
        raise SafeError('기존 ALB 파라미터가 중복되거나 예상과 다릅니다. 값은 표시하지 않고 중단합니다.')
    # JSON Patch test prevents appending twice if another operator wins a race.
    return [{'op': 'test', 'path': '/spec/source/helm/parameters', 'value': parameters}, *additions]


class Live(Operator):
    # Unlike older tools, do not retain raw error output even in last-error.log.
    def run(self, command, stdin=None):
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True,
                                text=True, input=stdin)
        if result.returncode:
            raise SafeError('하위 명령 실패. 원본 출력은 저장·표시하지 않습니다. 해당 도구를 비공개 환경에서 점검하세요.')
        return result.stdout

    def k(self, *args):
        return ['kubectl', '--context', self.args.context, *args]

    def get(self, kind, name=None, namespace=None):
        command = self.k('get', kind)
        if namespace == '*':
            command += ['--all-namespaces']
        elif namespace:
            command += ['-n', namespace]
        if name:
            command += [name]
        # --ignore-not-found permits absence only; RBAC/network errors still fail closed.
        if kind == 'secret':
            raw = self.run(command + ['--ignore-not-found', '-o', 'name'])
            return {'exists': True} if raw.strip() else None
        raw = self.run(command + ['--ignore-not-found', '-o', 'json'])
        return json.loads(raw) if raw.strip() else None

    def items(self, kind, namespace=None):
        return (self.get(kind, namespace=namespace) or {}).get('items', [])

    def cluster(self):
        # list-clusters disambiguates actual absence from AccessDenied/transport failure.
        names = self.aws('eks', 'list-clusters')['clusters']
        if self.args.cluster_name not in names:
            return None
        return self.aws('eks', 'describe-cluster', '--name', self.args.cluster_name)['cluster']

    def destination(self):
        c = self.cluster()
        if not c:
            raise SafeError('EKS가 없습니다. 부분 적용/삭제 상태를 확인하세요.')
        config = json.loads(self.run(self.k('config', 'view', '--minify', '-o', 'json')))
        verify_destination(c, config, self.args.expected_account_id, self.args.context)
        outputs = self.outputs()
        arn = c['arn'].split(':', 5)
        if (len(arn) != 6 or arn[2] != 'eks' or arn[3] != REGION
                or arn[4] != self.args.expected_account_id or arn[5] != 'cluster/' + self.args.cluster_name
                or c.get('name') != self.args.cluster_name
                or outputs.get('cluster_name') != self.args.cluster_name
                or outputs.get('cluster_endpoint') != c['endpoint']
                or not outputs.get('node_security_group_id')):
            raise SafeError('Terraform state와 실제 계정·리전·클러스터가 다릅니다.')
        # Nodes use a launch-template SG, not EKS resourcesVpcConfig.securityGroupIds.
        groups = self.aws('ec2', 'describe-security-groups',
                          payload={'GroupIds': [outputs['node_security_group_id']]})['SecurityGroups']
        group = groups[0] if len(groups) == 1 else {}
        tags = {t['Key']: t['Value'] for t in group.get('Tags', [])}
        if (group.get('GroupId') != outputs['node_security_group_id']
                or group.get('OwnerId') != self.args.expected_account_id
                or group.get('VpcId') != c['resourcesVpcConfig']['vpcId']
                or group.get('GroupName') != self.args.cluster_name + '-nodes'
                or tags.get('Project') != self.args.cluster_name.removesuffix('-eks')
                or tags.get('Stack') != 'eks' or tags.get('ManagedBy') != 'terraform'):
            raise SafeError('Terraform 노드 SG가 승인 계정·VPC·EKS 소유 태그와 다릅니다.')
        return c

    def cleanup_gate(self):
        # Operator invokes this AFTER backend init, again for both destroy plan and apply.
        self.destination()
        super().cleanup_gate()

    def outputs(self, stack='eks'):
        raw = self.run(['terraform', '-chdir=infra/environments/' + stack, 'output', '-json'])
        return {k: v['value'] for k, v in json.loads(raw).items()}

    def tfvars(self):
        # Terraform console evaluates HCL; no fragile shell/HCL text parsing. No init/apply here.
        result = self.run(['terraform', '-chdir=infra/environments/eks', 'console'],
                          'nonsensitive(jsonencode({ip=var.admin_public_access_cidrs,public=var.public_enabled,dns=var.public_dns_enabled,mode=var.public_access_mode,testers=var.alb_tester_cidrs,project=var.project_name}))\n')
        return json.loads(json.loads(result.strip()))

    def data_vars(self):
        raw = self.run(['terraform', '-chdir=infra/environments/data', 'console'],
                       'jsonencode({copy=var.eks_dev_secret_copy_enabled,nodes=var.eks_node_security_group_ids,role="${local.ec2_name}-k3s-host"})\n')
        return json.loads(json.loads(raw.strip()))

    def app(self, name):
        return self.get('application', name, 'argocd')

    def deployment(self, name, ns):
        d = self.get('deployment', name, ns)
        return bool(d and d.get('status', {}).get('observedGeneration', 0) >= d['metadata']['generation']
                    and d.get('status', {}).get('availableReplicas', 0) >= d['spec'].get('replicas', 1)
                    and d.get('status', {}).get('updatedReplicas', 0) == d['spec'].get('replicas', 1))

    def secret_metadata(self, name):
        # describe-secret never fetches secret values. Errors are NOT interpreted as absent.
        names = self.aws('secretsmanager', 'list-secrets', '--include-planned-deletion')['SecretList']
        return next((s for s in names if s['Name'] == name and not s.get('DeletedDate')), None)

    def albs(self):
        cluster = self.destination()
        result = []
        for lb in self.aws('elbv2', 'describe-load-balancers')['LoadBalancers']:
            if lb.get('VpcId') != cluster['resourcesVpcConfig']['vpcId']:
                continue
            tags = self.aws('elbv2', 'describe-tags', payload={'ResourceArns': [lb['LoadBalancerArn']]})['TagDescriptions']
            if any(t['Key'] == 'elbv2.k8s.aws/cluster' and t['Value'] == self.args.cluster_name
                   for t in tags[0]['Tags']):
                result.append(lb)
        return result

    def alb_verified(self):
        self.child(('register_lbc_app.py', 'verify'))
        return self.albs()

    def alb_cidrs(self):
        lbs = self.alb_verified()
        ids = [a['SubnetId'] for a in lbs[0]['AvailabilityZones']]
        subnets = self.aws('ec2', 'describe-subnets', payload={'SubnetIds': ids})['Subnets']
        return sorted(s['CidrBlock'] for s in subnets)

    def child(self, tool, confirm=False):
        command = [sys.executable, str(ROOT / 'scripts/eks' / tool[0]), *tool[1:], '--profile', self.args.profile]
        if tool[0] != 'seed_prod_secrets.py':
            command += ['--context', self.args.context, '--cluster-name', self.args.cluster_name]
        if tool[0] == 'bootstrap_argocd.py':
            command += ['--expected-account-id', self.args.expected_account_id]
        if confirm:
            if tool[0] in ('seed_prod_secrets.py', 'bootstrap_prod_db.py', 'copy_prod_content.py', 'register_secrets_app.py'):
                env = tool[-1] if '--env' in tool else 'prod'
                if self.args.confirm_env != env:
                    raise SafeError('이 단계는 --confirm-env에 대상 환경을 명시해야 합니다.')
                command += ['--confirm-env', env]
            else:
                if self.args.confirm_cluster != self.args.cluster_name:
                    raise SafeError('이 단계는 --confirm-cluster에 대상 클러스터를 명시해야 합니다.')
                command += ['--confirm-cluster', self.args.confirm_cluster]
        self.run(command)

    def binding(self):
        c = self.cluster()
        # Binding never exposes identifiers; prevents reusing receipts across cluster recreation/account.
        return fingerprint([self.args.expected_account_id, self.args.cluster_name,
                            c.get('createdAt') if c else None])

    def receipt_target(self):
        # DB tasks depend on persistent data state and current secret version, not just a step flag.
        return fingerprint([self.binding(), self.outputs('data'),
                            {k: (self.secret_metadata('ureka/eks/prod/app') or {}).get(k) for k in ('ARN', 'LastChangedDate')}])

    def check(self, key, state):
        if key == 'access':
            value = os.environ.get('UREKA_CURRENT_IPV4', '')
            try:
                ip = ipaddress.IPv4Address(value)
            except ipaddress.AddressValueError:
                raise SafeError('현재 공인 IPv4를 read -s로 입력하세요. 값은 출력하지 않습니다.') from None
            cidrs = self.tfvars()['ip']
            allowed = any(ip in ipaddress.ip_network(c) for c in cidrs)
            c = self.cluster()
            if c and c['resourcesVpcConfig'].get('endpointPublicAccess'):
                allowed = allowed and any(ip in ipaddress.ip_network(v) for v in c['resourcesVpcConfig']['publicAccessCidrs'])
            return allowed
        if key == 'infra':
            c = self.cluster()
            if not c or c['status'] != 'ACTIVE':
                check_phase_settings('infra', self.tfvars())
                return False
            outputs = self.outputs()
            if outputs.get('cluster_name') != self.args.cluster_name or outputs.get('cluster_endpoint') != c['endpoint']:
                raise SafeError('Terraform 출력과 실제 클러스터가 다릅니다. 부분 적용 여부 확인 필요.')
            groups = self.aws('eks', 'list-nodegroups', '--cluster-name', self.args.cluster_name)['nodegroups']
            return bool(groups) and all(self.aws('eks', 'describe-nodegroup', '--cluster-name', self.args.cluster_name,
                                                '--nodegroup-name', g)['nodegroup']['status'] == 'ACTIVE' for g in groups)
        if key in ('data', 'data-removed'):
            outputs = self.outputs()
            sg = outputs.get('node_security_group_id')
            data_sg = self.outputs('data').get('security_group_id')
            if not sg or not data_sg:
                raise SafeError('EKS/data 출력이 없습니다. 부분 적용 가능성이 있으므로 중단합니다.')
            groups = self.aws('ec2', 'describe-security-groups', '--filters', 'Name=ip-permission.group-id,Values=' + sg)['SecurityGroups']
            configured = self.data_vars()['nodes']
            if key == 'data':
                return configured == [sg] and any(g['GroupId'] == data_sg and any(p.get('IpProtocol') == 'tcp' and p.get('FromPort') == 5432 and p.get('ToPort') == 5432
                           and any(x['GroupId'] == sg for x in p.get('UserIdGroupPairs', [])) for p in g.get('IpPermissions', [])) for g in groups)
            c = self.destination()
            return not configured and not any(g['GroupId'] not in (sg, c['resourcesVpcConfig']['clusterSecurityGroupId']) for g in groups)
        if key == 'context':
            self.destination()
            nodes = self.items('nodes')
            return len(nodes) >= 2 and all(ready(n) for n in nodes)
        if key == 'argocd':
            return self.deployment('argocd-server', 'argocd')
        if key == 'controllers':
            crds = ('rollouts.argoproj.io', 'externalsecrets.external-secrets.io', 'secretstores.external-secrets.io')
            return (all(ready(self.get('crd', c) or {}, 'Established') for c in crds)
                    and self.deployment('argo-rollouts', 'argo-rollouts')
                    and self.deployment('external-secrets', 'external-secrets')
                    and self.get('secret', 'argocd-initial-admin-secret', 'argocd') is None)
        if key == 'dev-secrets':
            v = self.data_vars()
            policies = self.aws('iam', 'list-role-policies', '--role-name', v['role'])['PolicyNames']
            return (not v['copy'] and 'eks-dev-secret-copy' not in policies
                    and all(self.secret_metadata('ureka/eks/dev/' + n) for n in ('app', 'chat-ai')))
        if key == 'prod-seed':
            return bool(self.secret_metadata('ureka/eks/prod/app'))
        if key in ('prod-db', 'content'):
            # Only a successful invocation of the existing verified Job can issue this receipt.
            # No metadata-only `check` is treated as proof of actual DB contents.
            return state.get('receipts', {}).get(key) == self.receipt_target()
        if key == 'root':
            return bool(self.app('ureka-eks-root') and healthy(self.app('ureka-eks-root')) and all((self.get('namespace', ns) or {}).get('metadata', {}).get('labels', {}).get('pod-security.kubernetes.io/enforce') == 'restricted' for ns in ('dev', 'prod')))
        if key in ('secrets-dev', 'secrets-prod'):
            env = key.split('-')[1]
            a = self.app('ureka-eks-secrets-' + env)
            es = self.items('externalsecrets', env)
            return bool(a and healthy(a) and es and all(ready(s) for s in es))
        if key == 'services':
            apps = [self.app(f'ureka-{s}-eks-{env}') for env in ('dev', 'prod') for s in SERVICES]
            rollouts = [self.get('rollout', 'ureka-auth', env) for env in ('dev', 'prod')]
            return (all(a and healthy(a) for a in apps) and all(r and not r.get('status', {}).get('pauseConditions')
                    and r.get('status', {}).get('stableRS') and r['status'].get('stableRS') == r['status'].get('currentPodHash')
                    and str(r['status'].get('observedGeneration')) == str(r['metadata']['generation']) for r in rollouts))
        if key in ('public-infra', 'dns'):
            v = self.tfvars()
            if v['mode'] != 'testers':
                raise SafeError('이 도구는 testers만 지원합니다. open 전환은 별도 공개 승인 절차를 따르세요.')
            if key == 'public-infra' and v['dns']:
                # DNS enablement is a later resume only; a fresh public-infra stage requires false.
                if not all(state.get('steps', {}).get(k, {}).get('result') in ('success', 'skipped')
                           for k in ('public-infra', 'alb-policy', 'targets')):
                    raise SafeError('공개 인프라 단계는 public_dns_enabled=false가 필요합니다.')
            if not v['public'] or (key == 'dns' and not v['dns']):
                return False
            # Applied WAF and IAM presence, not merely edited tfvars.
            roles = self.aws('iam', 'list-roles')['Roles']
            acls = self.aws('wafv2', 'list-web-acls', '--scope', 'REGIONAL')['WebACLs']
            if not any(r['RoleName'] == 'ureka-eks-aws-load-balancer-controller' for r in roles) or not any(a['Name'] == 'ureka-eks-public' for a in acls):
                return False
            sg = self.aws('ec2', 'describe-security-groups', '--filters', 'Name=group-name,Values=ureka-eks-alb-public')['SecurityGroups']
            if len(sg) != 1:
                return False
            ingress = sg[0].get('IpPermissions', [])
            if len(ingress) != 2 or {r.get('FromPort') for r in ingress} != {80, 443}:
                raise SafeError('실제 공개 입구 SG의 포트가 예상과 다릅니다.')
            for rule in ingress:
                refs = rule.get('PrefixListIds', [])
                if (rule.get('IpProtocol') != 'tcp' or rule.get('ToPort') != rule.get('FromPort')
                        or rule.get('IpRanges') or rule.get('Ipv6Ranges') or rule.get('UserIdGroupPairs') or len(refs) != 1):
                    raise SafeError('실제 공개 입구 SG가 testers 전용이 아닙니다.')
                entries = self.aws('ec2', 'get-managed-prefix-list-entries', '--prefix-list-id', refs[0]['PrefixListId'])['Entries']
                if not entries or sorted(e['Cidr'] for e in entries) != sorted(v['testers']):
                    raise SafeError('실제 시험자 목록이 비공개 입력과 다릅니다.')
            if key == 'public-infra':
                return True
            # Terraform state must contain the actual managed alias; tfvars alone is insufficient.
            values = json.loads(self.run(['terraform', '-chdir=infra/environments/eks', 'show', '-json']))
            def resources(module):
                return module.get('resources', []) + [r for m in module.get('child_modules', []) for r in resources(m)]
            aliases = [r for r in resources(values['values']['root_module']) if r['type'] == 'aws_route53_record'
                       and r.get('values', {}).get('type') == 'A' and r.get('values', {}).get('alias')]
            # Confirm actual Route53 records, not just stale Terraform state.
            for r in aliases:
                v = r['values']
                records = self.aws('route53', 'list-resource-record-sets', '--hosted-zone-id', v['zone_id'])['ResourceRecordSets']
                if any(x['Name'].rstrip('.') == v['name'].rstrip('.') and x['Type'] == 'A'
                       and x.get('AliasTarget', {}).get('DNSName', '').rstrip('.') == v['alias'][0]['name'].rstrip('.') for x in records):
                    return True
            return False
        if key == 'lbc':
            return self.deployment('aws-load-balancer-controller', 'kube-system')
        if key == 'ingress':
            a = self.app('ureka-prod-public-ingress')
            return bool(a and healthy(a) and len(self.albs()) == 1)
        if key == 'alb-policy':
            params = self.app('ureka-eks-root')['spec']['source']['helm']['parameters']
            unchanged = not cidr_patch(params, self.alb_cidrs())
            a = self.app('ureka-eks-networkpolicy-prod')
            return bool(unchanged and a and healthy(a))
        if key == 'targets':
            lbs = self.alb_verified()
            groups = self.aws('elbv2', 'describe-target-groups', payload={'LoadBalancerArn': lbs[0]['LoadBalancerArn']})['TargetGroups']
            if len(groups) < 5:
                return False
            for g in groups:
                targets = self.aws('elbv2', 'describe-target-health', payload={'TargetGroupArn': g['TargetGroupArn']})['TargetHealthDescriptions']
                if not targets or any(t['TargetHealth']['State'] != 'healthy' for t in targets):
                    return False
            return True
        if key == 'connections':
            limit = os.environ.get('UREKA_DB_CONNECTION_LIMIT', '')
            if not re.fullmatch(r'[1-9][0-9]*', limit):
                raise SafeError('PM과 합의한 UREKA_DB_CONNECTION_LIMIT를 입력하세요(기본값 없음).')
            # Resolve the shared RDS from its live SG, never print its identifier.
            sg = self.outputs('data')['security_group_id']
            dbs = [d for d in self.aws('rds', 'describe-db-instances')['DBInstances'] if any(s['VpcSecurityGroupId'] == sg for s in d['VpcSecurityGroups'])]
            if len(dbs) != 1:
                raise SafeError('공유 RDS를 하나로 식별하지 못했습니다.')
            end = datetime.now(timezone.utc)
            from datetime import timedelta
            data = self.aws('cloudwatch', 'get-metric-statistics', payload={
                'Namespace': 'AWS/RDS', 'MetricName': 'DatabaseConnections',
                'Dimensions': [{'Name': 'DBInstanceIdentifier', 'Value': dbs[0]['DBInstanceIdentifier']}],
                'StartTime': (end - timedelta(minutes=5)).isoformat(), 'EndTime': end.isoformat(),
                'Period': 60, 'Statistics': ['Maximum']})['Datapoints']
            return bool(data) and max(d['Maximum'] for d in data) <= int(limit)
        if key == 'ingress-removed':
            return self.app('ureka-prod-public-ingress') is None and not self.items('ingress', 'prod')
        if key == 'alb-gone':
            return not self.albs()
        if key == 'apps-removed':
            # Recheck ALB here too: controller must not be destroyed while any ALB remains.
            if self.albs() or self.app('ureka-eks-root'):
                return False
            apps = self.items('applications', 'argocd')
            return (not any(a['metadata']['name'].startswith(('ureka-',)) for a in apps)
                    and all(not self.items(k, ns) for ns in ('dev', 'prod') for k in ('pods', 'pvc', 'ingress'))
                    and not self.items('pvc', '*')
                    and not any(s.get('spec', {}).get('type') == 'LoadBalancer' for s in self.items('service', '*')))
        if key == 'destroy':
            return self.cluster() is None and not self.outputs()
        if key == 'residue':
            # Verify all Terraform-owned tagged resources, plus known public entry names.
            project = self.tfvars()['project']
            resources = self.aws('resourcegroupstaggingapi', 'get-resources', payload={
                'TagFilters': [{'Key': 'Project', 'Values': [project]}, {'Key': 'Stack', 'Values': ['eks']}]})['ResourceTagMappingList']
            # Deleted resources can remain indexed briefly; wait rather than assert cleanup.
            if resources or self.cluster() is not None or self.outputs():
                return False
            acls = self.aws('wafv2', 'list-web-acls', '--scope', 'REGIONAL')['WebACLs']
            if any(a['Name'] == 'ureka-eks-public' for a in acls):
                return False
            # Tag APIs do not cover untagged/controller volumes, stale DNS and every ENI.
            # Explicit inventory review remains a human checkpoint; never infer from EKS absence.
            return self.args.confirm_residue == self.args.cluster_name
        raise SafeError('알 수 없는 단계입니다.')

    def execute(self, step, state):
        if step.tool and step.tool[0] == 'operate.py':
            args = argparse.Namespace(**vars(self.args))
            args.confirm_cleanup = self.args.confirm_cleanup
            op = Live(args)
            # Existing Operator methods call their own approval, source, freshness and cleanup gates.
            # Capture even progress output; only allowlisted review path/token are printed below.
            if self.args.review_dir or self.args.confirm:
                if not self.args.review_dir or not self.args.confirm:
                    raise SafeError('review-dir와 confirm을 함께 지정하세요.')
                folder = Path(self.args.review_dir).resolve()
                if folder.parent != (ROOT / '.local/eks').resolve():
                    raise SafeError('이 worktree의 review 폴더만 허용합니다.')
                review = json.loads((folder / 'review.json').read_text())
                if (bool(review.get('destroy')) != (step.key == 'destroy')
                        or review.get('lifecycle_step') != step.key):
                    raise SafeError('현재 단계와 다른 종류의 plan입니다. 이 단계에서 새 plan을 만드세요.')
                with contextlib.redirect_stdout(io.StringIO()):
                    plan = json.loads(op.tf('show', '-json', str(folder / 'saved.tfplan')))
                check_plan_scope(plan, step.key, self.args.cluster_name)
                if step.key == 'dns' and not self.check('targets', state):
                    raise SafeError('DNS 적용 전 ALB 대상이 healthy여야 합니다.')
                args.review_dir = str(folder)
                args.confirm = self.args.confirm
                with contextlib.redirect_stdout(io.StringIO()):
                    op.apply()
            else:
                if step.key != 'destroy':
                    check_phase_settings(step.key, self.tfvars())
                if step.key == 'dns' and not self.check('targets', state):
                    raise SafeError('DNS plan 전 ALB 대상이 healthy여야 합니다.')
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    op.plan(destroy=step.key == 'destroy')
                # Derive the path from the known private artifact root, never echo arbitrary output.
                match = re.search(r'plan 저장 위치: (\.local/eks/review-[A-Za-z0-9_-]+)', output.getvalue())
                if not match:
                    raise SafeError('저장된 plan 경로를 확인하지 못했습니다.')
                folder = ROOT / match.group(1)
                review = json.loads((folder / 'review.json').read_text())
                with contextlib.redirect_stdout(io.StringIO()):
                    plan = json.loads(op.tf('show', '-json', str(folder / 'saved.tfplan')))
                check_plan_scope(plan, step.key, self.args.cluster_name)
                review['lifecycle_step'] = step.key
                with (folder / 'review.json').open('w') as handle:
                    os.fchmod(handle.fileno(), 0o600)
                    json.dump(review, handle, sort_keys=True)
                token = hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest()
                print('새 plan:', folder.relative_to(ROOT))
                print('확인값:', token)
                print('plan.log를 비공개로 검토 후 같은 --execute 단계에 --review-dir 경로 --confirm 확인값 추가. 유효 1시간/재사용 금지는 기존 도구가 검사.')
            return
        self.destination()  # Before ANY Kubernetes mutation, verify live destination again.
        if step.key == 'alb-policy':
            if self.args.confirm_cluster != self.args.cluster_name:
                raise SafeError('CIDR 주입은 --confirm-cluster 확인이 필요합니다.')
            app = self.app('ureka-eks-root')
            patch = cidr_patch(app['spec']['source']['helm']['parameters'], self.alb_cidrs())
            if patch:
                self.run(self.k('patch', 'application', 'ureka-eks-root', '-n', 'argocd', '--type=json', '--patch-file=/dev/stdin'), json.dumps(patch))
            return
        if not step.tool:
            raise SafeError('이 단계는 안내된 기존 절차를 사람이 실행한 뒤 다시 확인해야 합니다.')
        names = {'root': 'ureka-eks-root', 'secrets-dev': 'ureka-eks-secrets-dev',
                 'secrets-prod': 'ureka-eks-secrets-prod', 'lbc': 'aws-load-balancer-controller'}
        if step.key in names and self.app(names[step.key]):
            # Registered but not yet Ready: wait for Sync; never clobber injected root parameters.
            return
        tool = ('copy_prod_content.py', 'verify') if step.key == 'content' and self.args.verify_existing else step.tool
        self.child(tool, confirm=True)
        if step.key in ('prod-db', 'content'):
            state.setdefault('receipts', {})[step.key] = self.receipt_target()


def now():
    return datetime.now(timezone.utc).isoformat()


def shared_lock_root():
    # Resolve Git's shared administrative directory without a subprocess or private input files.
    admin = ROOT / '.git'
    if admin.is_file():
        text = admin.read_text().strip()
        if not text.startswith('gitdir: '):
            raise SafeError('공유 Git 잠금 위치를 확인하지 못했습니다.')
        admin = (ROOT / text.removeprefix('gitdir: ')).resolve()
    common = admin / 'commondir'
    if common.is_file():
        admin = (admin / common.read_text().strip()).resolve()
    if not admin.is_dir():
        raise SafeError('공유 Git 잠금 위치가 없습니다.')
    return admin / 'ureka-lifecycle-locks'


@contextmanager
def locked_target(args):
    root = shared_lock_root()
    if root.is_symlink():
        raise SafeError('공유 잠금 폴더의 심볼릭 링크를 허용하지 않습니다.')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    key = fingerprint([args.expected_account_id, REGION, args.cluster_name])
    fd = os.open(root / (key + '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as handle:
        os.fchmod(handle.fileno(), 0o600)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SafeError('다른 worktree/방향에서 같은 대상 작업이 진행 중입니다.') from None
        yield


@contextmanager
def locked_state(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or path.is_symlink():
        raise SafeError('상태 경로의 심볼릭 링크를 허용하지 않습니다.')
    os.chmod(path.parent, 0o700)
    lock = path.parent.parent / 'lifecycle.lock'
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SafeError('같은 실행이 이미 진행 중입니다.') from None
        yield


def save(path, state):
    # No free-form strings/CLI output/identifiers enter this structure.
    tmp = path.with_suffix('.tmp')
    fd = os.open(tmp, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(state, f, indent=2, sort_keys=True)
    tmp.replace(path)


def summary(state):
    print('단계 | 결과 | 작업 초(재실행 포함)')
    total = 0.0
    for step in (UP if state['direction'] == 'up' else DOWN):
        key = step.key
        if key not in state['steps']:
            continue
        entry = state['steps'][key]
        elapsed = sum(a['seconds'] for a in entry['attempts'])
        total += elapsed
        print(f"{key} | {entry['result']} | {elapsed:.2f}")
    print(f'작업 합계: {total:.2f}초 (사람 대기 시간 제외)')
    elapsed = (datetime.fromisoformat(state.get('finished', now())) - datetime.fromisoformat(state['started'])).total_seconds()
    print(f'전체 경과: {elapsed:.2f}초 (중간 사람 대기 시간 포함, 완료 전에는 잠정값)')


def workflow(args, live, path):
    steps = UP if args.direction == 'up' else DOWN
    with locked_state(path), locked_target(args):
        state = json.loads(path.read_text()) if path.exists() else dict(version=1, direction=args.direction, started=now(), steps={}, receipts={})
        if state.get('version') != 1 or state.get('direction') != args.direction:
            raise SafeError('다른 형식/방향의 상태 파일입니다.')
        live.identity()
        if args.direction == 'down' and live.cluster() is not None:
            # Before even the first cleanup hint/check, tie context to the actual Terraform state.
            live.destination()
        binding = live.binding()
        if state.get('binding') not in (None, binding):
            # Up may cross the intentional no-cluster -> created boundary only before infra success.
            if not (args.direction == 'up' and state.get('steps', {}).get('infra', {}).get('result') not in ('success', 'skipped')):
                # Down may cross intentional destroy boundary only after preceding gates succeeded.
                if not (args.direction == 'down' and all(state.get('steps', {}).get(s.key, {}).get('result') in ('success', 'skipped') for s in DOWN[:6]) and live.cluster() is None):
                    raise SafeError('대상 계정/클러스터 생성 시점이 바뀌었습니다. 새 실행 폴더로 시작하세요.')
        account_binding = fingerprint([args.expected_account_id, args.cluster_name, args.context])
        if state.get('account_binding', account_binding) != account_binding:
            raise SafeError('대상 계정/이름이 다른 실행 기록입니다.')
        state['account_binding'] = account_binding
        state['binding'] = binding
        # After destroy the old kube context no longer exists. Never replay prerequisites against it.
        destroyed = args.direction == 'down' and live.cluster() is None
        if destroyed and not all(state['steps'].get(s.key, {}).get('result') in ('success', 'skipped') for s in DOWN[:6]):
            raise SafeError('검증된 삭제 전 단계 기록 없이 클러스터가 없습니다. 부분 적용 복구/잔존 확인 필요.')
        state.pop('finished', None)
        executed = False
        for step in steps:
            if destroyed and step.key not in ('destroy', 'residue'):
                continue
            entry = state['steps'].setdefault(step.key, dict(attempts=[], result='pending'))
            start, wall = now(), time.monotonic()
            outcome = 'failed'
            try:
                if args.direction == 'down' and step.key != 'residue' and live.cluster() is not None:
                    live.destination()
                # Explicit re-verification invalidates the old receipt before starting a Job.
                # A failed recheck must not be skipped by a subsequent normal resume.
                force_verify = (step.key == 'content' and args.execute == 'content'
                                and args.verify_existing and not executed)
                if force_verify:
                    state['receipts'].pop('content', None)
                    save(path, state)
                # Fresh checks, even for previously successful steps; never trust a step flag.
                if live.check(step.key, state) and not force_verify:
                    outcome = 'skipped'
                elif args.execute == step.key and not executed:
                    print('실행 중:', step.key, step.title, flush=True)
                    live.execute(step, state)
                    executed = True
                    outcome = 'success' if live.check(step.key, state) else 'waiting'
                else:
                    if args.execute and not executed:
                        print('지정 단계보다 앞선 미완료 단계가 있어 실행하지 않습니다.')
                    outcome = 'waiting'
                if step.key in ('infra', 'destroy') and outcome in ('success', 'skipped'):
                    state['binding'] = live.binding()
                entry['result'] = outcome
            finally:
                entry['result'] = outcome
                entry['attempts'].append(dict(started=start, finished=now(), seconds=round(time.monotonic()-wall, 3), result=outcome))
                save(path, state)
                if outcome == 'failed':
                    print('실패 단계:', step.key, step.title)
                    print(step.hint)
                    summary(state)
            if outcome == 'waiting':
                print('여기서 멈춤:', step.key, step.title)
                print(step.hint)
                if step.tool or step.key == 'alb-policy':
                    print('한 단계 실행: 같은 명령에 --execute', step.key, '및 해당 --confirm-env/--confirm-cluster 추가. 자동 승인 없음.')
                summary(state)
                return 2
        state['finished'] = now()
        save(path, state)
        summary(state)
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('direction', choices=('up', 'down'))
    parser.add_argument('--plan-only', action='store_true')
    parser.add_argument('--run-id', help='같은 날짜에 별도 실행할 때 YYYYMMDD-HHMMSS 형식 지정')
    parser.add_argument('--profile', default=os.environ.get('UREKA_OPS_PROFILE', ''))
    parser.add_argument('--cluster-name', default='ureka-eks')
    parser.add_argument('--context', default='ureka-eks')
    parser.add_argument('--execute', choices=tuple(dict.fromkeys(s.key for s in (*UP, *DOWN) if s.tool or s.key == 'alb-policy')))
    parser.add_argument('--review-dir')
    parser.add_argument('--confirm')
    parser.add_argument('--confirm-cleanup')
    parser.add_argument('--confirm-residue')
    parser.add_argument('--verify-existing', action='store_true', help='content 단계에서 기존 prod를 읽기 전용 대조, COPY 없음')
    parser.add_argument('--confirm-env', choices=('dev', 'prod'))
    parser.add_argument('--confirm-cluster')
    args = parser.parse_args(argv)
    if args.plan_only:
        for i, s in enumerate(UP if args.direction == 'up' else DOWN, 1):
            print(f'{i:02d}. {s.key}: {s.title}\n   전제/확인: {s.hint}')
        print('외부 호출·파일 생성 없음. 각 단계는 실제 상태 확인 → 필요 시 사람 승인 실행 → 결과 확인. state: .local/eks/<up|down>-<날짜>/state.json')
        return 0
    try:
        account = os.environ.get('UREKA_EXPECTED_ACCOUNT_ID', '')
        if not re.fullmatch(r'[0-9]{12}', account) or not args.profile:
            raise SafeError('프로필과 read -s로 입력한 UREKA_EXPECTED_ACCOUNT_ID가 필요합니다.')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', args.cluster_name) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', args.context):
            raise SafeError('클러스터·context 이름 형식을 확인하세요.')
        run_id = args.run_id or datetime.now(ZoneInfo('Asia/Seoul')).strftime('%Y%m%d')
        if not re.fullmatch(r'[0-9]{8}(?:-[0-9]{6})?', run_id):
            raise SafeError('run-id는 YYYYMMDD 또는 YYYYMMDD-HHMMSS 형식입니다.')
        args.expected_account_id = account
        return workflow(args, Live(args), ROOT / '.local/eks' / f'{args.direction}-{run_id}' / 'state.json')
    except (SafeError, OSError, ValueError, KeyError, TypeError, IndexError, KeyboardInterrupt):
        # Exceptions can embed a sensitive path/value; deliberately do not interpolate them.
        print('중단: 입력·권한·연결·기존 상태를 확인하세요. 민감한 원본 출력은 표시하지 않습니다.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
