"""dev 들어오는 연결 정책을 계산해 허용 표(expected.json)와 정확히 같은지 본다. 표준 라이브러리만 쓴다.

사용: python3 check_matrix.py expected.json <시나리오 이름> <정책 JSON 파일>...
정책 JSON은 `yq -o=json -I=0`로 바꾼 NetworkPolicy(한 줄에 하나)다.

NetworkPolicy 의미(ingress만):
- 어떤 정책도 고르지 않은 Pod는 모두 받는다. 하나라도 고르면 그 정책들의 ingress 규칙 합집합만 받는다.
- 규칙 하나는 from(여러 항목 중 하나라도 맞으면) AND ports(비면 모든 포트).
- from 항목에 namespaceSelector·podSelector가 같이 있으면 AND. podSelector만 있으면 정책과 같은 네임스페이스.
- from을 빼거나 빈 목록이면 모든 출발지, ports를 빼거나 빈 목록이면 모든 포트.
- podSelector {}는 그 네임스페이스의 모든 Pod, namespaceSelector {}는 모든 네임스페이스.
ipBlock은 EKS 기대 표의 allowIpBlock=true일 때만 지원한다(기본 EC2 경로는 거부).
지원하지 않는 형식(matchExpressions, 이름 포트, endPort, 빈 peer {})은 잘못 계산하지 않게
비교 전에 정책 전체를 검사해 실패로 처리한다(빈 peer는 API 서버도 거절한다: "must specify a peer").
"""
import ipaddress
import json
import sys


class Unsupported(Exception):
    pass


def fail(msg):
    raise Unsupported(msg)


def match_labels(selector, labels, what):
    if selector is None:
        return None
    if set(selector) - {"matchLabels"}:
        fail(f"{what}: matchLabels 말고는 지원하지 않는다: {selector}")
    return all(labels.get(k) == v for k, v in (selector.get("matchLabels") or {}).items())


def validate(policies, allow_ipblock=False):
    """비교 전에 모든 정책의 모든 분기를 검사한다(선택되지 않는 분기도 빠뜨리지 않게)."""
    for pol in policies:
        name = pol["metadata"]["name"]
        spec = pol["spec"]
        match_labels(spec.get("podSelector", {}), {}, name)
        for rule in spec.get("ingress") or []:
            for peer in rule.get("from") or []:
                if not peer:
                    fail(f"{name}: 빈 peer {{}}는 지원하지 않는다(API도 거절)")
                if allow_ipblock and "ipBlock" in peer:
                    if set(peer) != {"ipBlock"} or set(peer["ipBlock"]) - {"cidr", "except"}:
                        fail(f"{name}: invalid ipBlock peer")
                    try:
                        network = ipaddress.ip_network(peer["ipBlock"]["cidr"])
                        for exception in peer["ipBlock"].get("except", []):
                            if not ipaddress.ip_network(exception).subnet_of(network):
                                fail(f"{name}: ipBlock except outside CIDR")
                    except (ValueError, KeyError, TypeError):
                        fail(f"{name}: invalid ipBlock CIDR")
                    continue
                if set(peer) - {"namespaceSelector", "podSelector"}:
                    fail(f"{name}: 지원하지 않는 from 항목(ipBlock 등): {peer}")
                for key in ("namespaceSelector", "podSelector"):
                    if key in peer:
                        match_labels(peer[key], {}, name)
            for p in rule.get("ports") or []:
                if "endPort" in p or not isinstance(p.get("port"), int):
                    fail(f"{name}: 숫자 포트만 지원한다: {p}")


def peer_matches(peer, src, policy_ns, name):
    if "ipBlock" in peer:
        if not src.get("ip"):
            return False
        ip = ipaddress.ip_address(src["ip"])
        block = peer["ipBlock"]
        return ip in ipaddress.ip_network(block["cidr"]) and not any(
            ip in ipaddress.ip_network(x) for x in block.get("except", []))
    if src.get("external"):
        return False
    ns_sel = peer.get("namespaceSelector")
    pod_sel = peer.get("podSelector")
    ns_labels = {"kubernetes.io/metadata.name": src["namespace"]}
    ns_ok = match_labels(ns_sel, ns_labels, name) if ns_sel is not None else src["namespace"] == policy_ns
    pod_ok = match_labels(pod_sel, src["labels"], name) if pod_sel is not None else True
    return ns_ok and pod_ok


def port_matches(ports, port, name):
    if not ports:
        return True
    for p in ports:
        if "endPort" in p or not isinstance(p.get("port"), int):
            fail(f"{name}: 숫자 포트만 지원한다: {p}")
        if p.get("protocol", "TCP") == "TCP" and p["port"] == port:
            return True
    return False


def allowed(policies, src, target_labels, port, target_namespace="dev"):
    selecting = []
    for pol in policies:
        spec = pol["spec"]
        if pol["metadata"].get("namespace") != target_namespace:
            continue
        if "Ingress" not in spec.get("policyTypes", ["Ingress"]):
            continue
        if match_labels(spec.get("podSelector", {}), target_labels, pol["metadata"]["name"]):
            selecting.append(pol)
    if not selecting:
        return True
    for pol in selecting:
        name = pol["metadata"]["name"]
        for rule in pol["spec"].get("ingress") or []:
            peers = rule.get("from")
            peer_ok = True if not peers else any(peer_matches(p, src, target_namespace, name) for p in peers)
            if peer_ok and port_matches(rule.get("ports"), port, name):
                return True
    return False


def main():
    expected_path, scenario, *policy_files = sys.argv[1:]
    exp = json.load(open(expected_path, encoding="utf-8"))
    scenarios = list(exp["allow"])
    if scenario not in scenarios:
        print(f"::error::시나리오가 없다: {scenario} (있는 것: {scenarios})")
        sys.exit(1)
    allow = set()
    for s in (scenarios[: scenarios.index(scenario) + 1] if exp.get("cumulative", True) else [scenario]):
        allow |= {tuple(x) for x in exp["allow"][s]}
    policies = []
    for path in policy_files:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and line != "---":
                doc = json.loads(line)
                if doc and doc.get("kind") == "NetworkPolicy":
                    policies.append(doc)
    try:
        validate(policies, allow_ipblock=exp.get("allowIpBlock", False))
    except Unsupported as e:
        print(f"::error::{e}")
        sys.exit(1)
    for a in allow:
        if a[0] not in exp["sources"] or a[1] not in exp["targets"] or a[2] not in exp["targets"][a[1]]:
            print(f"::error::허용 표 항목이 sources·targets에 없다: {a}")
            sys.exit(1)

    errors, checked = [], 0
    for src_name, src in exp["sources"].items():
        for target, ports in exp["targets"].items():
            for port in ports:
                checked += 1
                got = allowed(policies, src, {"app.kubernetes.io/name": target}, port, exp.get("namespace", "dev"))
                want = (src_name, target, port) in allow
                if got != want:
                    errors.append(f"{src_name} → {target}:{port} 계산={'허용' if got else '차단'}, 표={'허용' if want else '차단'}")
    print(f"[{scenario}] 정책 {len(policies)}개, 조합 {checked}개, 허용 {len(allow)}개")
    if errors:
        for e in errors:
            print(f"::error::{e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
