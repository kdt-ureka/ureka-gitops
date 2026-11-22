#!/usr/bin/env python3
"""EKS 앱 구성(#43) 정적 검사. 클러스터 없이 scripts/check-charts.sh가 렌더링한 결과(JSON 줄)를 본다.

작업 폴더 파일(<work>/):
- apps.jsonl: helm template argocd/eks/apps (시험용 레지스트리 주입)
- <env>-svc.jsonl: 서비스 7개를 base + environments/eks/<env> values로 렌더링한 결과
- <env>-data.jsonl: kubectl kustomize environments/eks/<env>/data
- <env>-namespace.jsonl: kubectl kustomize environments/eks/<env>/namespace (#62, 있으면)
- ec2-svc.jsonl: EC2 dev 서비스 렌더링(이미지 비교 안내용)

검사: AppProject 범위, Application 프로젝트·목적지·동기화, 렌더된 자원 종류가 프로젝트 허용 목록 안인지,
prod/dev DB·주소 분리, 비밀값 평문 없음, dev 1개·auth 카나리, Quota 안(데이터 계층 포함).
"""
import json
import math
import sys
from pathlib import Path

REPO = "https://github.com/kdt-ureka/ureka-gitops.git"
SERVER = "https://kubernetes.default.svc"
ENVS = ("dev", "prod")
PROJECTS = {"ureka-eks-platform", "ureka-eks-dev", "ureka-eks-prod"}
SECRET_ENV = {"DB_PASSWORD", "JWT_PRIVATE_KEY", "JWT_PUBLIC_KEY", "EMAIL_CODE_SECRET",
              "INTERNAL_SERVICE_TOKEN", "AI_API_KEY", "AI_MODE"}
# 업무 프로젝트에 절대 넣지 않는 종류(Secret은 ESO만, 권한은 플랫폼 프로젝트만)
FORBIDDEN_IN_ENV_PROJECT = {("", "Secret"), ("rbac.authorization.k8s.io", "Role"),
                            ("rbac.authorization.k8s.io", "RoleBinding"), ("", "ServiceAccount"),
                            ("", "ResourceQuota"), ("", "LimitRange")}
DB_KEYS = ("DB_URL", "DATABASE_URL")
AUTH_CPU_REQUEST = "100m"
# prod Argo CD 역할이 가질 수 있는 것: auth 앱 조회와 Rollout 동작뿐(sync·update·delete·logs·exec 없음, #62에서 넘김)
ROLE_OBJECT = "ureka-eks-prod/ureka-auth-eks-prod"
ROLE_ACTIONS = {"get"} | {f"action/argoproj.io/Rollout/{a}" for a in ("resume", "promote-full", "abort", "retry")}


def load(path):
    path = Path(path)
    if not path.exists():
        return None
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and line not in ("---", "null"):
            obj = json.loads(line)
            if obj:
                out.append(obj)
    return out


def group_of(obj):
    api = obj.get("apiVersion", "")
    return api.split("/")[0] if "/" in api else ""


def cpu_m(v):
    s = str(v)
    return int(s[:-1]) if s.endswith("m") else int(float(s) * 1000)


def mem_mi(v):
    s = str(v)
    for unit, mul in (("Ki", 1 / 1024), ("Mi", 1), ("Gi", 1024)):
        if s.endswith(unit):
            return float(s[:-2]) * mul
    return float(s) / (1024 * 1024)


def containers(obj):
    spec = obj.get("spec", {}).get("template", {}).get("spec", {})
    return spec.get("containers", []) + (spec.get("initContainers") or [])


def workloads(objs):
    return [o for o in objs if o.get("kind") in ("Deployment", "Rollout", "Job", "StatefulSet")]


def env_values(objs):
    """(workload name, env name, value or None if valueFrom)"""
    for o in workloads(objs):
        for c in containers(o):
            for e in c.get("env") or []:
                yield o["metadata"]["name"], e["name"], e.get("value"), e.get("valueFrom")


def check_projects(apps):
    errors = []
    projects = {o["metadata"]["name"]: o for o in apps if o.get("kind") == "AppProject"}
    if set(projects) != PROJECTS:
        return [f"AppProject는 {sorted(PROJECTS)}여야 한다: {sorted(projects)}"]
    for name, p in projects.items():
        spec = p["spec"]
        if spec.get("sourceRepos") != [REPO]:
            errors.append(f"{name}: sourceRepos는 이 저장소 하나만: {spec.get('sourceRepos')}")
        dests = spec.get("destinations") or []
        if any(d.get("server") != SERVER or "*" in d.get("namespace", "*") for d in dests):
            errors.append(f"{name}: 목적지는 클러스터 안·이름 고정 네임스페이스만: {dests}")
        if p["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave") != "-3":
            errors.append(f"{name}: sync-wave -3(앱보다 먼저)이 아니다")
        allowed = {(w.get("group", ""), w["kind"]) for w in spec.get("namespaceResourceWhitelist") or []}
        if any(g == "*" or k == "*" for g, k in allowed):
            errors.append(f"{name}: 허용 목록에 * 가 있다")
        if spec.get("namespaceResourceBlacklist") or spec.get("clusterResourceBlacklist"):
            errors.append(f"{name}: blacklist 방식은 쓰지 않는다(허용 목록만)")
    plat = projects["ureka-eks-platform"]["spec"]
    if sorted(d["namespace"] for d in plat["destinations"]) != sorted(ENVS):
        errors.append("ureka-eks-platform: 목적지는 dev·prod 둘")
    # Argo CD는 클러스터 범위 자원에 destinations 검사를 하지 않는다. name이 비면 모든 Namespace가 허용된다.
    cluster = sorted((c.get("group", ""), c.get("kind"), c.get("name", "")) for c in plat.get("clusterResourceWhitelist") or [])
    if cluster != sorted(("", "Namespace", env) for env in ENVS):
        errors.append(f"ureka-eks-platform: 클러스터 범위는 Namespace dev·prod(이름 명시)만: {cluster}")
    for env in ENVS:
        spec = projects[f"ureka-eks-{env}"]["spec"]
        if [d["namespace"] for d in spec["destinations"]] != [env]:
            errors.append(f"ureka-eks-{env}: 목적지는 {env} 하나만: {spec['destinations']}")
        if spec.get("clusterResourceWhitelist"):
            errors.append(f"ureka-eks-{env}: 클러스터 범위 자원을 허용하면 안 된다")
        allowed = {(w.get("group", ""), w["kind"]) for w in spec.get("namespaceResourceWhitelist") or []}
        bad = allowed & FORBIDDEN_IN_ENV_PROJECT
        if bad:
            errors.append(f"ureka-eks-{env}: 업무 프로젝트에 허용하면 안 되는 종류: {sorted(bad)}")
        if not (spec.get("orphanedResources") or {}).get("warn"):
            errors.append(f"ureka-eks-{env}: orphanedResources.warn이 꺼져 있다")
    for name, p in projects.items():
        for role in p["spec"].get("roles") or []:
            if name != "ureka-eks-prod" or role.get("jwtTokens"):
                errors.append(f"{name}: 역할 {role.get('name')}은 prod auth 카나리 역할만 둔다(토큰 없음)")
            for policy in role.get("policies") or []:
                parts = [x.strip() for x in policy.split(",")]
                if len(parts) != 6 or parts[0] != "p" or parts[1] != f"proj:{name}:{role.get('name')}" \
                        or parts[2] != "applications" or parts[3] not in ROLE_ACTIONS \
                        or parts[4] != ROLE_OBJECT or parts[5] != "allow":
                    errors.append(f"{name}: 허용 밖 Argo CD 정책: {policy}")
    return errors


def app_role(app):
    name = app["metadata"]["name"]
    if name.startswith("ureka-eks-namespace-"):
        return "namespace", name.rsplit("-", 1)[1]
    if name.startswith("ureka-eks-data-"):
        return "data", name.rsplit("-", 1)[1]
    if "-eks-" in name:
        return "service", name.rsplit("-", 1)[1]
    return "unknown", ""


def check_applications(apps, prod_auto=False):
    errors = []
    projects = {o["metadata"]["name"]: o["spec"] for o in apps if o.get("kind") == "AppProject"}
    seen = {}
    for app in (o for o in apps if o.get("kind") == "Application"):
        name, spec = app["metadata"]["name"], app["spec"]
        role, env = app_role(app)
        if env not in ENVS:
            errors.append(f"{name}: 이름으로 환경을 알 수 없다")
            continue
        seen.setdefault((role, env), []).append(name)
        want_project = "ureka-eks-platform" if role == "namespace" else f"ureka-eks-{env}"
        if spec.get("project") != want_project:
            errors.append(f"{name}: 프로젝트가 {want_project}가 아니다: {spec.get('project')}")
        dest = spec.get("destination", {})
        if dest.get("server") != SERVER or dest.get("namespace") != env:
            errors.append(f"{name}: 목적지가 {env}가 아니다: {dest}")
        proj = projects.get(spec.get("project"), {})
        if dest.get("namespace") not in [d["namespace"] for d in proj.get("destinations", [])]:
            errors.append(f"{name}: 프로젝트가 허용하지 않는 목적지")
        sources = spec.get("sources") or [spec.get("source")]
        for s in sources:
            if s.get("repoURL") != REPO or s.get("targetRevision") != "main":
                errors.append(f"{name}: 저장소·브랜치가 다르다")
            for vf in (s.get("helm") or {}).get("valueFiles", []):
                if not (vf.startswith("../../environments/base/") or vf.startswith(f"../../environments/eks/{env}/")):
                    errors.append(f"{name}: 다른 환경 values를 본다: {vf}")
            if s.get("path", "").startswith("environments/") and not s["path"].startswith(f"environments/eks/{env}/"):
                errors.append(f"{name}: 다른 환경 경로를 본다: {s['path']}")
        auto = (spec.get("syncPolicy") or {}).get("automated")
        if role == "namespace" or env == "dev":
            if not auto or auto.get("prune") is not True or auto.get("selfHeal") is not True:
                errors.append(f"{name}: 자동 동기화(prune·selfHeal)여야 한다")
        elif auto and not prod_auto:
            errors.append(f"{name}: prod 업무 앱은 수동 Sync여야 한다(automated 없음)")
    for env in ENVS:
        for role in ("namespace", "data", "service"):
            if not seen.get((role, env)):
                errors.append(f"{env}: {role} 앱이 없다")
    return errors


def whitelist(spec):
    return ({(w.get("group", ""), w["kind"]) for w in spec.get("namespaceResourceWhitelist") or []},
            {(w.get("group", ""), w["kind"], w.get("name", "")) for w in spec.get("clusterResourceWhitelist") or []})


def check_kinds(apps, rendered):
    """rendered: {(role, env): objs}. 각 앱이 만드는 자원 종류가 프로젝트 허용 목록 안인지."""
    errors = []
    projects = {o["metadata"]["name"]: o["spec"] for o in apps if o.get("kind") == "AppProject"}
    for (role, env), objs in rendered.items():
        if objs is None:
            continue
        project = "ureka-eks-platform" if role == "namespace" else f"ureka-eks-{env}"
        ns_ok, cluster_ok = whitelist(projects[project])
        for o in objs:
            key = (group_of(o), o["kind"])
            if o["kind"] == "Namespace":
                if key + (o["metadata"]["name"],) not in cluster_ok:
                    errors.append(f"{env}/{role}: 프로젝트 {project}가 Namespace {o['metadata']['name']}를 허용하지 않는다")
                elif o["metadata"]["name"] != env:
                    errors.append(f"{env}/{role}: 다른 이름 Namespace {o['metadata']['name']}")
                continue
            if key not in ns_ok:
                errors.append(f"{env}/{role}: {project} 허용 목록 밖 종류 {key}: {o['metadata'].get('name')}")
            ns = o["metadata"].get("namespace")
            if ns not in (None, env):
                errors.append(f"{env}/{role}: 다른 네임스페이스 자원 {o['kind']}/{o['metadata']['name']} ns={ns}")
            if o["kind"] == "Service" and o.get("spec", {}).get("type") in ("LoadBalancer", "NodePort"):
                errors.append(f"{env}/{role}: {o['spec']['type']} Service는 만들지 않는다(공개는 #64 Ingress)")
    return errors


def check_env_values(env, objs):
    errors = []
    other = "prod" if env == "dev" else "dev"
    for wl, name, value, value_from in env_values(objs):
        if name in SECRET_ENV and (value is not None or "secretKeyRef" not in (value_from or {})):
            errors.append(f"{env}/{wl}: {name}은 Secret 참조여야 한다(평문 값 금지)")
        if value is None:
            continue
        if name in DB_KEYS:
            db = value.rsplit("/", 1)[-1]
            if (env == "prod") != db.endswith("_prod"):
                errors.append(f"{env}/{wl}: {name}의 DB 이름이 환경과 맞지 않다: {db}")
            if name == "DATABASE_URL":
                user = value.split("://", 1)[1].split(":", 1)[0]
                if (env == "prod") != user.endswith("_prod_app"):
                    errors.append(f"{env}/{wl}: DATABASE_URL 계정이 환경과 맞지 않다: {user}")
        if name == "DB_USERNAME" and (env == "prod") != value.endswith("_prod_app"):
            errors.append(f"{env}/{wl}: DB_USERNAME이 환경과 맞지 않다: {value}")
        if f".{other}.svc" in value:
            errors.append(f"{env}/{wl}: {name}이 {other} 네임스페이스를 가리킨다: {value}")
        if name == "COOKIE_SECURE" and value != ("true" if env == "prod" else "false"):
            errors.append(f"{env}/{wl}: COOKIE_SECURE={value}")
    return errors


def check_shape(env, svc):
    errors = []
    by_name = {o["metadata"]["name"]: o for o in workloads(svc) if o["kind"] != "Job"}
    auth = by_name.get("ureka-auth")
    if not auth or auth["kind"] != "Rollout":
        errors.append(f"{env}: ureka-auth가 Rollout(카나리)이 아니다")
    else:
        req = containers(auth)[0].get("resources", {}).get("requests", {})
        if req.get("cpu") != AUTH_CPU_REQUEST:
            errors.append(f"{env}: auth CPU 요청이 {AUTH_CPU_REQUEST}가 아니다: {req.get('cpu')}")
    for name, o in by_name.items():
        replicas = o["spec"].get("replicas", 1)
        if env == "dev" and replicas != 1:
            errors.append(f"dev: {name} replicas={replicas}(dev는 모두 1)")
    if env == "prod" and auth and auth["spec"].get("replicas") != 2:
        errors.append("prod: auth는 2개(50% 카나리)여야 한다")
    for o in workloads(svc):
        for c in containers(o):
            if "@sha256:" not in c.get("image", ""):
                errors.append(f"{env}: {o['metadata']['name']} 이미지가 digest 고정이 아니다")
    return errors


def pod_req(o):
    cpu = mem = lcpu = lmem = 0
    for c in o["spec"]["template"]["spec"]["containers"]:
        r = c.get("resources") or {}
        cpu += cpu_m(r.get("requests", {}).get("cpu", "50m"))
        mem += mem_mi(r.get("requests", {}).get("memory", "64Mi"))
        lcpu += cpu_m(r.get("limits", {}).get("cpu", "500m"))
        lmem += mem_mi(r.get("limits", {}).get("memory", "256Mi"))
    return cpu, mem, lcpu, lmem


def surge(o):
    """롤링 업데이트 때 더 뜨는 파드 수(#62 검사기와 같은 방식: 렌더된 strategy를 읽는다)."""
    n = o["spec"].get("replicas", 1)
    if o["kind"] == "Rollout":
        return max(1, math.ceil(n * 0.25))
    strategy = o["spec"].get("strategy") or {}
    if strategy.get("type") == "Recreate":
        return 0
    value = str((strategy.get("rollingUpdate") or {}).get("maxSurge", "25%"))
    return math.ceil(n * int(value[:-1]) / 100) if value.endswith("%") else int(value)


def check_quota(env, svc, data, ns_objs):
    """모든 앱 동시 갱신(롤링 surge·auth 카나리 새 파드·chat 마이그레이션 Job)을 데이터 계층까지 더해 Quota와 비교."""
    if ns_objs is None:
        return []
    quota = [o for o in ns_objs if o.get("kind") == "ResourceQuota"]
    if len(quota) != 1:
        return [f"{env}: ResourceQuota가 하나가 아니다"]
    hard = quota[0]["spec"]["hard"]
    tot = [0, 0.0, 0, 0.0]
    pods = 0
    for o in workloads(svc) + workloads(data):
        r = pod_req(o)
        n = 1 if o["kind"] == "Job" else o["spec"].get("replicas", 1) + surge(o)
        tot = [a + b * n for a, b in zip(tot, r)]
        pods += n
    errors = []
    checks = (("requests.cpu", tot[0], cpu_m), ("requests.memory", tot[1], mem_mi),
              ("limits.cpu", tot[2], cpu_m), ("limits.memory", tot[3], mem_mi))
    for key, used, conv in checks:
        if key in hard and used > conv(hard[key]):
            errors.append(f"{env}: 최대치 {key} {used:g}가 Quota {hard[key]}를 넘는다(데이터 계층 포함)")
    if "pods" in hard and pods > int(hard["pods"]):
        errors.append(f"{env}: 최대 파드 {pods}가 Quota {hard['pods']}를 넘는다")
    print(f"{env}: 최대(동시 갱신+카나리+마이그레이션+데이터) 요청 {tot[0]}m·{tot[1]:g}Mi, 상한 {tot[2]}m·{tot[3]:g}Mi, 파드 {pods}"
          f" / Quota {hard.get('requests.cpu')}·{hard.get('requests.memory')}, {hard.get('limits.cpu')}·{hard.get('limits.memory')}")
    return errors


def images(objs):
    return {o["metadata"]["name"]: containers(o)[0]["image"].split("@")[1]
            for o in workloads(objs or []) if o["kind"] != "Job"}


def report_images(ec2, dev, prod):
    """흐름(EC2 dev → EKS dev → EKS prod)은 PR이 따로라 잠깐 다를 수 있다. 실패가 아니라 안내만 한다."""
    a, b, c = images(ec2), images(dev), images(prod)
    for name in sorted(b):
        line = "같음" if a.get(name) == b[name] == c.get(name) else \
            f"EC2 {a.get(name, '-')[7:19]} / dev {b[name][7:19]} / prod {c.get(name, '-')[7:19]}"
        print(f"image {name}: {line}")
        if line != "같음":
            print(f"::notice::{name} 이미지가 환경마다 다르다(승격 대기인지 확인): {line}")


def run(work):
    work = Path(work)
    apps = load(work / "apps.jsonl")
    errors = check_projects(apps) + check_applications(apps)
    rendered = {}
    for env in ENVS:
        svc, data, ns = (load(work / f"{env}-{k}.jsonl") for k in ("svc", "data", "namespace"))
        if ns is None:
            print(f"::warning::environments/eks/{env}/namespace가 없다(#62 미병합). 종류·Quota 검사 일부를 건너뛴다.")
        rendered[("service", env)] = svc
        rendered[("data", env)] = data
        rendered[("namespace", env)] = ns
        errors += check_env_values(env, svc) + check_shape(env, svc) + check_quota(env, svc, data, ns)
        if any(o.get("kind") == "Secret" for o in svc + data):
            errors.append(f"{env}: Git 렌더 결과에 Secret이 있다(Secret은 ESO만 만든다)")
    errors += check_kinds(apps, rendered)
    report_images(load(work / "ec2-svc.jsonl"), rendered[("service", "dev")], rendered[("service", "prod")])
    return errors


def main():
    errors = run(sys.argv[1])
    for e in errors:
        print(f"::error::{e}")
    print("EKS 앱 구성 검사:", "실패" if errors else "통과")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
