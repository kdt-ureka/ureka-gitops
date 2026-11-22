"""EKS dev·prod 네임스페이스(#62) 정적 검사. python3 표준 라이브러리만 쓴다.

입력은 scripts/test-eks-namespaces.sh가 만든 JSON Lines(한 줄에 Kubernetes 객체 하나)다.
- <env>-ns.jsonl: kubectl kustomize environments/eks/<env>/namespace 결과
- <env>-workloads.jsonl: 서비스 7개를 그 환경 values로 helm template한 결과
- ec2-ns.jsonl: EC2 dev 네임스페이스(Pod Security 라벨 비교 기준)

검사:
1. Pod Security restricted 라벨이 EC2 dev와 같다.
2. 서비스 평상시·카나리 최대치(새 파드 1개 더 + 마이그레이션 Job)가 ResourceQuota 안에 들어간다.
3. 모든 컨테이너가 LimitRange 최대치 이하이고, LimitRange 기본값이 최대치 이하다.
4. LB·NodePort Service 0, 두 환경 Quota 요청 합 + 시스템 몫이 노드 2대 추정 용량 안에 들어간다.
5. prod RBAC: 사람 그룹은 읽기 전용, 플랫폼 그룹은 ureka-auth Rollout patch와 로그 조회만.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

# t3.large 2대(2 vCPU·8GiB) 추정 allocatable. EKS AL2023 기본 kube-reserved·eviction을 뺀 값이며 실측 전이다.
NODE_COUNT = 2
NODE_ALLOCATABLE_CPU_M = 1930
NODE_ALLOCATABLE_MEM_MI = 7100
# kube-system(CoreDNS·kube-proxy·VPC CNI·EBS CSI)·Argo CD·Argo Rollouts·관측 요청 추정. 실측 뒤 고친다.
SYSTEM_RESERVE_CPU_M = 600
SYSTEM_RESERVE_MEM_MI = 1536

EXPECTED_SERVICES = {
    "ureka-auth", "ureka-chat", "ureka-chat-worker", "ureka-content",
    "ureka-ops", "ureka-recommend", "ureka-frontend",
}
PSA_PREFIX = "pod-security.kubernetes.io/"

VIEWER_GROUP = "ureka-prod-viewers"
OPERATOR_GROUP = "ureka-prod-rollout-operators"
READ_VERBS = {"get", "list", "watch"}
# 사람 그룹에 절대 주지 않는 자원(값 노출·컨테이너 진입·우회 경로).
FORBIDDEN_RESOURCES = {
    "secrets", "pods/exec", "pods/attach", "pods/portforward", "pods/proxy",
    "services/proxy", "nodes/proxy", "serviceaccounts/token", "*",
}
CANARY_ROLLOUT = "ureka-auth"


def cpu_m(value) -> int:
    s = str(value)
    if s.endswith("m"):
        return int(s[:-1])
    return int(round(float(s) * 1000))


_MEM = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024}


def mem_mi(value) -> float:
    s = str(value)
    for suffix, factor in _MEM.items():
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * factor
    return float(s) / (1024 * 1024)


def load(path: str | Path) -> list[dict]:
    out = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and line != "---" and line != "null":
            out.append(json.loads(line))
    return out


def one(objs: list[dict], kind: str) -> dict:
    found = [o for o in objs if o.get("kind") == kind]
    if len(found) != 1:
        raise AssertionError(f"{kind}가 정확히 하나여야 한다: {len(found)}개")
    return found[0]


class Usage:
    def __init__(self) -> None:
        self.req_cpu = 0
        self.req_mem = 0.0
        self.lim_cpu = 0
        self.lim_mem = 0.0
        self.pods = 0

    def add_pod(self, spec: dict, count: int, limitrange: dict) -> None:
        r = pod_resources(spec, limitrange)
        self.req_cpu += r[0] * count
        self.req_mem += r[1] * count
        self.lim_cpu += r[2] * count
        self.lim_mem += r[3] * count
        self.pods += count

    def __repr__(self) -> str:
        return (f"요청 {self.req_cpu}m·{self.req_mem:.0f}Mi, 상한 {self.lim_cpu}m·{self.lim_mem:.0f}Mi, "
                f"파드 {self.pods}")


def container_limits_spec(limitrange: dict) -> dict:
    for item in limitrange["spec"]["limits"]:
        if item.get("type") == "Container":
            return item
    raise AssertionError("LimitRange에 type: Container가 없다")


def container_resources(c: dict, lr: dict) -> tuple[int, float, int, float]:
    res = c.get("resources") or {}
    req = res.get("requests") or {}
    lim = res.get("limits") or {}
    # LimitRange 동작: limit만 있으면 request=limit, 둘 다 없으면 defaultRequest/default.
    lim_cpu = cpu_m(lim.get("cpu", lr["default"]["cpu"]))
    lim_mem = mem_mi(lim.get("memory", lr["default"]["memory"]))
    req_cpu = cpu_m(req.get("cpu", lim.get("cpu", lr["defaultRequest"]["cpu"])))
    req_mem = mem_mi(req.get("memory", lim.get("memory", lr["defaultRequest"]["memory"])))
    return req_cpu, req_mem, lim_cpu, lim_mem


def pod_resources(spec: dict, limitrange: dict) -> tuple[int, float, int, float]:
    lr = container_limits_spec(limitrange)
    main = [container_resources(c, lr) for c in spec.get("containers", [])]
    init = [container_resources(c, lr) for c in spec.get("initContainers", []) or []]
    # 쿼터는 max(일반 컨테이너 합, 가장 큰 init 컨테이너)로 센다.
    totals = [sum(x[i] for x in main) for i in range(4)]
    for i in range(4):
        if init:
            totals[i] = max(totals[i], max(x[i] for x in init))
    return totals[0], totals[1], totals[2], totals[3]


def pod_spec(obj: dict) -> dict:
    return obj["spec"]["template"]["spec"]


def workload_usage(workloads: list[dict], limitrange: dict) -> tuple[Usage, Usage, set[str]]:
    """평상시와 최대(카나리 새 파드 + 마이그레이션 Job) 사용량."""
    steady, peak = Usage(), Usage()
    names = set()
    for obj in workloads:
        kind = obj.get("kind")
        if kind in ("Deployment", "Rollout"):
            names.add(obj["metadata"]["name"])
            replicas = int(obj["spec"].get("replicas", 1))
            steady.add_pod(pod_spec(obj), replicas, limitrange)
            extra = 0
            if kind == "Rollout":
                # 트래픽 라우팅 없는 canary: maxSurge 기본 25%(올림). 새 파드가 먼저 뜬 뒤 옛 파드를 줄인다.
                extra = max(1, math.ceil(replicas * 0.25))
            peak.add_pod(pod_spec(obj), replicas + extra, limitrange)
        elif kind == "Job":
            # Argo CD PreSync 마이그레이션 Job은 배포 중에만 있다(최대치에만 넣는다).
            peak.add_pod(pod_spec(obj), 1, limitrange)
        elif kind in ("StatefulSet", "DaemonSet", "CronJob", "Pod"):
            raise AssertionError(f"예상하지 못한 워크로드 종류: {kind} {obj['metadata'].get('name')}")
    return steady, peak, names


def check_namespace(env: str, ns_objs: list[dict], ec2_objs: list[dict]) -> list[str]:
    errors = []
    ns = one(ns_objs, "Namespace")
    if ns["metadata"]["name"] != env:
        errors.append(f"{env}: Namespace 이름이 {ns['metadata']['name']}")
    ec2 = one(ec2_objs, "Namespace")
    want = {k: v for k, v in ec2["metadata"]["labels"].items() if k.startswith(PSA_PREFIX)}
    got = {k: v for k, v in (ns["metadata"].get("labels") or {}).items() if k.startswith(PSA_PREFIX)}
    if got != want:
        errors.append(f"{env}: Pod Security 라벨이 EC2 dev와 다르다: {got} != {want}")
    if want.get(PSA_PREFIX + "enforce") != "restricted":
        errors.append("EC2 dev 기준 라벨이 enforce=restricted가 아니다(비교 기준이 바뀜)")
    if (ns["metadata"].get("annotations") or {}).get("argocd.argoproj.io/sync-options") != "Prune=false":
        errors.append(f"{env}: Namespace에 Prune=false가 없다")
    for o in ns_objs:
        if o["kind"] != "Namespace" and o["metadata"].get("namespace") != env:
            errors.append(f"{env}: {o['kind']}/{o['metadata']['name']}의 namespace가 {env}가 아니다")
        if o["kind"] == "NetworkPolicy":
            errors.append(f"{env}: NetworkPolicy는 #49 범위라 여기 두지 않는다")
    return errors


def check_quota(env: str, ns_objs: list[dict], workloads: list[dict]) -> tuple[list[str], dict]:
    errors = []
    quota = one(ns_objs, "ResourceQuota")["spec"]["hard"]
    limitrange = one(ns_objs, "LimitRange")
    lr = container_limits_spec(limitrange)

    for key in ("services.loadbalancers", "services.nodeports"):
        if str(quota.get(key)) != "0":
            errors.append(f"{env}: {key}가 0이 아니다({quota.get(key)})")
    for key in ("requests.cpu", "requests.memory", "limits.cpu", "limits.memory", "pods"):
        if key not in quota:
            errors.append(f"{env}: ResourceQuota에 {key}가 없다")
    if errors:
        return errors, quota

    max_cpu, max_mem = cpu_m(lr["max"]["cpu"]), mem_mi(lr["max"]["memory"])
    for name in ("default", "defaultRequest"):
        if cpu_m(lr[name]["cpu"]) > max_cpu or mem_mi(lr[name]["memory"]) > max_mem:
            errors.append(f"{env}: LimitRange {name}가 max보다 크다")
    if cpu_m(lr["defaultRequest"]["cpu"]) > cpu_m(lr["default"]["cpu"]) or \
            mem_mi(lr["defaultRequest"]["memory"]) > mem_mi(lr["default"]["memory"]):
        errors.append(f"{env}: LimitRange defaultRequest가 default보다 크다")

    for obj in workloads:
        if obj.get("kind") not in ("Deployment", "Rollout", "Job"):
            continue
        spec = pod_spec(obj)
        for c in spec.get("containers", []) + (spec.get("initContainers") or []):
            req_cpu, req_mem, lim_cpu, lim_mem = container_resources(c, lr)
            where = f"{env}: {obj['kind']}/{obj['metadata']['name']}/{c['name']}"
            if lim_cpu > max_cpu or lim_mem > max_mem:
                errors.append(f"{where} 상한 {lim_cpu}m·{lim_mem:.0f}Mi가 LimitRange max를 넘는다")
            if req_cpu > lim_cpu or req_mem > lim_mem:
                errors.append(f"{where} 요청이 상한보다 크다")

    steady, peak, names = workload_usage(workloads, limitrange)
    missing = EXPECTED_SERVICES - names
    if missing:
        errors.append(f"{env}: 렌더링 결과에 서비스가 없다: {sorted(missing)}")
    print(f"[{env}] 평상시 {steady}")
    print(f"[{env}] 최대(카나리+마이그레이션) {peak}")
    checks = [
        ("requests.cpu", peak.req_cpu, cpu_m(quota["requests.cpu"])),
        ("requests.memory", peak.req_mem, mem_mi(quota["requests.memory"])),
        ("limits.cpu", peak.lim_cpu, cpu_m(quota["limits.cpu"])),
        ("limits.memory", peak.lim_mem, mem_mi(quota["limits.memory"])),
        ("pods", peak.pods, int(quota["pods"])),
    ]
    for key, used, hard in checks:
        pct = 100 * used / hard if hard else float("inf")
        print(f"[{env}]   {key}: 최대 {used:.0f} / 상한 {hard:.0f} ({pct:.0f}%)")
        if used > hard:
            errors.append(f"{env}: 카나리 최대치 {key} {used:.0f}가 ResourceQuota {hard:.0f}를 넘는다")
    return errors, quota


def check_cluster_fit(quotas: dict[str, dict]) -> list[str]:
    errors = []
    cap_cpu = NODE_COUNT * NODE_ALLOCATABLE_CPU_M
    cap_mem = NODE_COUNT * NODE_ALLOCATABLE_MEM_MI
    req_cpu = SYSTEM_RESERVE_CPU_M + sum(cpu_m(q["requests.cpu"]) for q in quotas.values())
    req_mem = SYSTEM_RESERVE_MEM_MI + sum(mem_mi(q["requests.memory"]) for q in quotas.values())
    print(f"[클러스터] 두 환경 Quota 요청 합 + 시스템 추정: CPU {req_cpu}m / {cap_cpu}m, "
          f"메모리 {req_mem:.0f}Mi / {cap_mem}Mi (추정 allocatable, 노드 {NODE_COUNT}대)")
    if req_cpu > cap_cpu:
        errors.append(f"두 환경 Quota CPU 요청 합 + 시스템 {req_cpu}m가 노드 용량 추정 {cap_cpu}m를 넘는다")
    if req_mem > cap_mem:
        errors.append(f"두 환경 Quota 메모리 요청 합 + 시스템 {req_mem:.0f}Mi가 노드 용량 추정 {cap_mem}Mi를 넘는다")
    return errors


def check_rbac(prod_objs: list[dict], prod_workloads: list[dict]) -> list[str]:
    errors = []
    for o in prod_objs:
        if o["kind"] in ("ClusterRole", "ClusterRoleBinding"):
            errors.append(f"prod RBAC에 클러스터 범위 객체가 있다: {o['kind']}/{o['metadata']['name']}")
    roles = {o["metadata"]["name"]: o for o in prod_objs if o["kind"] == "Role"}
    bindings = [o for o in prod_objs if o["kind"] == "RoleBinding"]

    group_rules: dict[str, list[dict]] = {}
    for b in bindings:
        ref = b["roleRef"]
        if ref.get("kind") != "Role" or ref["name"] not in roles:
            errors.append(f"RoleBinding/{b['metadata']['name']}가 prod Role이 아닌 것을 가리킨다: {ref}")
            continue
        for s in b.get("subjects") or []:
            if s.get("kind") != "Group":
                errors.append(f"RoleBinding/{b['metadata']['name']}에 Group이 아닌 대상: {s}")
                continue
            if s["name"].startswith("system:"):
                errors.append(f"그룹 이름은 system:으로 시작할 수 없다(EKS access entry): {s['name']}")
            group_rules.setdefault(s["name"], []).extend(roles[ref["name"]].get("rules") or [])

    if set(group_rules) != {VIEWER_GROUP, OPERATOR_GROUP}:
        errors.append(f"권한 그룹이 예상과 다르다: {sorted(group_rules)}")

    def rule_items(rule):
        for g in rule.get("apiGroups") or []:
            for r in rule.get("resources") or []:
                yield g, r

    for group, rules in group_rules.items():
        for rule in rules:
            verbs = set(rule.get("verbs") or [])
            if "*" in verbs or "*" in (rule.get("apiGroups") or []):
                errors.append(f"{group}: 와일드카드 권한 {rule}")
            for g, r in rule_items(rule):
                if r in FORBIDDEN_RESOURCES:
                    errors.append(f"{group}: 금지 자원 {g}/{r}")
                if verbs <= READ_VERBS and r != "pods/log":
                    continue
                if r == "pods/log" and verbs == {"get"}:
                    if group == VIEWER_GROUP:
                        errors.append(f"{VIEWER_GROUP}에 pods/log가 있다(prod 로그는 플랫폼 담당만)")
                    continue
                if (g == "argoproj.io" and r in ("rollouts", "rollouts/status") and "patch" in verbs
                        and verbs <= {"get", "patch"}
                        and rule.get("resourceNames") == [CANARY_ROLLOUT] and group == OPERATOR_GROUP):
                    continue
                errors.append(f"{group}: 읽기 외 권한 {g}/{r} {sorted(verbs)} {rule.get('resourceNames')}")

    op = group_rules.get(OPERATOR_GROUP, [])
    for sub in ("rollouts", "rollouts/status"):
        if not any(("argoproj.io", sub) in set(rule_items(r)) and "patch" in r.get("verbs", []) for r in op):
            errors.append(f"{OPERATOR_GROUP}에 {sub} patch가 없다(승격·중단 불가)")
    viewer = group_rules.get(VIEWER_GROUP, [])
    if not any(("argoproj.io", "rollouts") in set(rule_items(r)) and "get" in r.get("verbs", []) for r in viewer):
        errors.append(f"{VIEWER_GROUP}가 Rollout을 볼 수 없다")

    rollouts = [o["metadata"]["name"] for o in prod_workloads if o.get("kind") == "Rollout"]
    if rollouts != [CANARY_ROLLOUT]:
        errors.append(f"prod Rollout이 {CANARY_ROLLOUT} 하나가 아니다: {rollouts} (RBAC resourceNames와 맞춘다)")
    return errors


def run(workdir: str | Path) -> list[str]:
    w = Path(workdir)
    ec2 = load(w / "ec2-ns.jsonl")
    errors: list[str] = []
    quotas = {}
    for env in ("dev", "prod"):
        ns = load(w / f"{env}-ns.jsonl")
        wl = load(w / f"{env}-workloads.jsonl")
        errors += check_namespace(env, ns, ec2)
        errs, quota = check_quota(env, ns, wl)
        errors += errs
        quotas[env] = quota
        if env == "prod":
            errors += check_rbac(ns, wl)
        elif any(o["kind"] in ("Role", "RoleBinding") for o in ns):
            errors.append("dev 네임스페이스 앱에 RBAC이 있다(이번 범위는 prod만)")
    if all("requests.cpu" in q and "requests.memory" in q for q in quotas.values()):
        errors += check_cluster_fit(quotas)
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("사용법: check_eks_namespaces.py <작업 폴더>", file=sys.stderr)
        return 2
    errors = run(argv[1])
    for e in errors:
        print(f"::error::{e}")
    if not errors:
        print("EKS 네임스페이스 검사 통과")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
