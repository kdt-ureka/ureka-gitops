#!/usr/bin/env python3
"""Offline only: read approved public-subnet CIDRs from stdin, emit root Application JSON patch.
Never calls AWS/kubectl. Output contains private topology: pipe directly to approved kubectl patch, never tee/commit.
"""
import ipaddress
import json
import sys


def patch(cidrs):
    if not isinstance(cidrs, list) or not 1 <= len(cidrs) <= 8 or len(set(cidrs)) != len(cidrs):
        raise ValueError("expected 1..8 distinct subnet CIDRs")
    private = [ipaddress.ip_network(c) for c in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']]
    for cidr in cidrs:
        network = ipaddress.ip_network(cidr)
        if network.version != 4 or network.prefixlen < 16 or not any(network.subnet_of(p) for p in private):
            raise ValueError("expected approved private IPv4 ALB subnet CIDRs, /16 or narrower")
    parameters = [{"name": "networkPolicy.alb.enabled", "value": "true"}]
    parameters += [{"name": f"networkPolicy.alb.sourceCidrs[{i}]", "value": cidr} for i, cidr in enumerate(cidrs)]
    # Append to the existing ecrRegistry parameter list; never replace or expose it.
    return [{"op": "add", "path": "/spec/source/helm/parameters/-", "value": p} for p in parameters]


def main():
    try:
        print(json.dumps(patch(json.load(sys.stdin))))
    except (ValueError, TypeError, KeyError):
        print("ALB CIDR 입력 형식이 잘못됐습니다(값은 출력하지 않음)", file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
