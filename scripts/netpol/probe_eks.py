#!/usr/bin/env python3
"""EKS dev/prod TCP probe. Only explicit invocation creates temporary Deployments.
No policy/app/namespace already present is changed; each source runs sequentially (Quota).
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("probe_compare", ROOT / "tests/networkpolicy/probe_compare.py")
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


def probe_table(table):
    table = json.loads(json.dumps(table))
    table["sources"] = {k: v for k, v in table["sources"].items() if v.get("probe", True)}
    for key, rows in table["allow"].items():
        table["allow"][key] = [r for r in rows if r[0] in table["sources"]]
    return table


def deployment(source, image, name, run):
    labels = {**source["labels"], "ureka-netpol-probe": run}
    pod = {
        "metadata": {"labels": labels},
        "spec": {"automountServiceAccountToken": False, "terminationGracePeriodSeconds": 0,
                 "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                     "seccompProfile": {"type": "RuntimeDefault"}},
                 "containers": [{"name": "probe", "image": image,
                                 "command": ["python", "-c", "import time; time.sleep(1800)"],
                                 # Never a Ready Service endpoint, even if a broad Service selector matches these labels.
                                 "readinessProbe": {"exec": {"command": ["python", "-c", "raise SystemExit(1)"]}, "periodSeconds": 5},
                                 "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                                               "limits": {"cpu": "100m", "memory": "64Mi"}},
                                 "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                                     "capabilities": {"drop": ["ALL"]}}}]}}
    return {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": name, "namespace": source["namespace"],
            "labels": {"ureka-netpol-probe": run}}, "spec": {"replicas": 1,
            "selector": {"matchLabels": {"ureka-netpol-probe": run, "probe-source": name}},
            "template": {**pod, "metadata": {"labels": {**labels, "probe-source": name}}}}}


def endpoint_contains(data, pod):
    # AWS PolicyEndpoint spec.podSelectorEndpoints[].{podIP,name,namespace}.
    for item in data.get("items", []):
        if "Ingress" not in item.get("spec", {}).get("podIsolation", []):
            continue
        for endpoint in item.get("spec", {}).get("podSelectorEndpoints", []):
            if (endpoint.get("podIP") == pod["status"]["podIP"]
                    and endpoint.get("name") == pod["metadata"]["name"]
                    and endpoint.get("namespace") == pod["metadata"]["namespace"]):
                return True
    return False


CHECKER = '''import concurrent.futures,socket,sys,time

def check(pair):
    name,port,ip=pair.split(":")
    for _ in range(3):
        try:
            socket.create_connection((ip,int(port)),timeout=3).close()
            return f"{name}:{port} 허용"
        except OSError as error:
            reason=type(error).__name__
            time.sleep(1)
    return f"{name}:{port} 차단 {reason}"
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    for row in pool.map(check,sys.argv[1:]): print(row)
'''


class Runner:
    def __init__(self, args):
        self.args = args
        self.prefix = ["kubectl", "--context", args.context, "--request-timeout=30s"]
        self.run_id = uuid.uuid4().hex[:10]
        self.created_namespaces = []
        self.created = []

    def k(self, *args, payload=None, optional=False):
        result = subprocess.run([*self.prefix, *args], input=json.dumps(payload) if payload else None,
                                text=True, capture_output=True)
        if result.returncode:
            if optional and "(NotFound)" in result.stderr:
                return None
            raise RuntimeError("kubectl 실패(권한·연결·Quota·자원 상태 확인, 원문은 출력하지 않음)")
        return result.stdout

    def get(self, *args, optional=False):
        result = self.k("get", *args, "-o", "json", optional=optional)
        return json.loads(result) if result is not None else None

    def cleanup(self):
        if self.args.keep:
            print(f"남긴 자원 selector: ureka-netpol-probe={self.run_id}")
            return
        for ns, name in reversed(self.created):
            self.k("-n", ns, "delete", "deployment", name, "--ignore-not-found", "--wait=true", "--timeout=90s")
        for ns in reversed(self.created_namespaces):
            data = self.get("namespace", ns)
            if data["metadata"].get("labels", {}).get("ureka-netpol-probe") == self.run_id:
                self.k("delete", "namespace", ns, "--wait=false")

    def execute(self):
        table = probe_table(json.loads(Path(self.args.expected).read_text()))
        if table.get("namespace") != self.args.namespace:
            raise RuntimeError("기대 표와 대상 namespace가 다릅니다")
        if self.args.scenario not in table["allow"]:
            raise RuntimeError("기대 표에 시나리오가 없습니다")
        targets = self.args.targets.split()
        # Validate before any mutation. Missing rows here are intentional; only configuration errors matter.
        errors, _ = pc.compare(table, self.args.scenario, targets, [], 0)
        if any(not e.startswith("결과 없음:") for e in errors):
            raise RuntimeError("받는 쪽:포트·시나리오 설정이 유효하지 않습니다")
        print(f"시험 자원 selector: ureka-netpol-probe={self.run_id}")
        for source in table["sources"].values():
            ns = source["namespace"]
            if self.get("namespace", ns, optional=True) is None:
                continue
            services = self.get("service", "-n", ns)
            for service in services["items"]:
                selector = service.get("spec", {}).get("selector")
                if (service.get("spec", {}).get("publishNotReadyAddresses") and selector
                        and all(source["labels"].get(k) == v for k, v in selector.items())):
                    raise RuntimeError("시험 Pod가 publishNotReadyAddresses Service에 들어갈 수 있어 중단합니다")
        chat = self.get("deployment", "ureka-chat", "-n", self.args.namespace)
        image = chat["spec"]["template"]["spec"]["containers"][0]["image"]
        pairs = []
        for target in targets:
            name, port = target.split(":")
            pods = self.get("pod", "-n", self.args.namespace, "-l", f"app.kubernetes.io/name={name},!ureka-netpol-probe")
            ready = [p for p in pods["items"] if p.get("status", {}).get("phase") == "Running" and any(
                c.get("type") == "Ready" and c.get("status") == "True" for c in p["status"].get("conditions", []))]
            if not ready:
                raise RuntimeError(f"Ready 대상이 없습니다: {name}")
            # Test every Ready replica (stable/candidate included), never just the first Pod.
            # Comparator expects one row per target, so reject mixed results across replicas below.
            for pod in ready:
                endpoints = self.get("policyendpoints.networking.k8s.aws", "-n", self.args.namespace)
                if not endpoint_contains(endpoints, pod):
                    raise RuntimeError(f"PolicyEndpoint에서 대상 Pod 적용을 확인하지 못했습니다: {name}")
                pairs.append(f'{name}:{port}:{pod["status"]["podIP"]}')
        rows = []
        for i, (source_name, source) in enumerate(table["sources"].items()):
            ns = source["namespace"]
            if self.get("namespace", ns, optional=True) is None:
                if ns in ("dev", "prod", "kube-system"):
                    raise RuntimeError("필수 namespace가 없습니다")
                self.k("create", "-f", "-", payload={"apiVersion": "v1", "kind": "Namespace", "metadata": {
                    "name": ns, "labels": {"ureka-netpol-probe": self.run_id, "pod-security.kubernetes.io/enforce": "restricted"}}})
                self.created_namespaces.append(ns)
            name = f"probe-{self.run_id}-{i}"
            self.k("create", "-f", "-", payload=deployment(source, image, name, self.run_id))
            self.created.append((ns, name))
            pod = None
            for _ in range(60):
                pods = self.get("pod", "-n", ns, "-l", f"probe-source={name},ureka-netpol-probe={self.run_id}")
                running = [p for p in pods["items"] if p.get("status", {}).get("phase") == "Running"]
                if running and all(c.get("state", {}).get("running") for c in running[0]["status"].get("containerStatuses", [])):
                    pod = running[0]
                    break
                time.sleep(2)
            if not pod:
                raise RuntimeError("시험 Deployment가 Running이 되지 않았습니다")
            # Allow control-plane/node policy convergence; never trust startup default-allow as evidence.
            time.sleep(10)
            raw = self.k("-n", ns, "exec", pod["metadata"]["name"], "--", "python", "-c", CHECKER, *pairs)
            per_target = {}
            for line in raw.splitlines():
                parts = line.split()
                if len(parts) < 2 or parts[1] not in ("허용", "차단"):
                    raise RuntimeError("시험 출력 형식 오류")
                per_target.setdefault(parts[0], []).append(parts[1])
            for target in targets:
                if len(per_target.get(target, [])) != sum(pair.startswith(target + ":") for pair in pairs):
                    raise RuntimeError("replica 결과가 누락됐습니다")
            for target, states in per_target.items():
                if len(set(states)) != 1:
                    raise RuntimeError("대상 replica마다 결과가 다릅니다")
                rows.append(f"{source_name} {target} {states[0]}")
            if not self.args.keep:
                self.k("-n", ns, "delete", "deployment", name, "--wait=true", "--timeout=90s")
                self.created.remove((ns, name))
        errors, compared = pc.compare(table, self.args.scenario, targets, rows, 0)
        for row in rows:
            print(row)
        print(f"TCP probe 조합 {len(compared)}개, 문제 {len(errors)}개; ALB·L7·노드 예외 시험은 별도")
        if errors:
            raise RuntimeError("허용 표와 실측 결과가 다릅니다")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", required=True, choices=("dev", "prod"))
    parser.add_argument("--expected")
    parser.add_argument("--scenario", default="baseline")
    parser.add_argument("--targets", default=os.environ.get("PROBE_TARGETS", "ureka-auth:8080 ureka-chat:8080 ureka-content:8080 ureka-ops:8080 ureka-recommend:8000 redis:6379 mailpit:1025"))
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.expected = args.expected or ROOT / f"tests/networkpolicy/eks-{args.namespace}.json"
    runner = Runner(args)
    try:
        runner.execute()
    except (RuntimeError, OSError, ValueError, KeyError, IndexError) as error:
        print(f"중단: {error}" if isinstance(error, RuntimeError) else "중단: 시험 도구/데이터 오류", file=sys.stderr)
        return 1
    finally:
        try:
            runner.cleanup()
        except (RuntimeError, OSError, ValueError):
            print(f"정리 실패: ureka-netpol-probe={runner.run_id} 자원을 확인하세요", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
