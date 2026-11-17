#!/usr/bin/env python3
"""Run on the EC2 CN shell. Values stay in memory/stdin; never in argv or logs."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--app-metrics', action='store_true')
args = parser.parse_args()
if os.geteuid() != 0 or not Path('/etc/rancher/k3s/k3s.yaml').is_file():
    sys.exit('EC2 k3s CN 셸에서 sudo로 실행하세요.')
os.environ['KUBECONFIG'] = '/etc/rancher/k3s/k3s.yaml'

def kube(*argv, data=None):
    p = subprocess.run(['kubectl', '--context', 'default', *argv], input=data,
                       text=True, capture_output=True)
    if p.returncode:
        # Kubernetes 오류에 값이 포함될 수 있어 원문은 출력하지 않는다.
        sys.exit('Kubernetes 요청 실패. Secret 값은 출력하지 않습니다.')
    return p.stdout

def read_secret(namespace, name):
    raw = kube('-n', namespace, 'get', 'secret', name, '--ignore-not-found', '-o', 'json')
    return json.loads(raw).get('data', {}) if raw.strip() else None

def create(name, data):
    manifest = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                'metadata': {'name': name, 'namespace': 'observability'},
                'data': {k: base64.b64encode(v).decode() for k, v in data.items()}}
    kube('create', '-f', '-', data=json.dumps(manifest))

if not read_secret('observability', 'ureka-grafana-admin'):
    create('ureka-grafana-admin', {'admin-user': b'admin',
                                 'admin-password': secrets.token_urlsafe(32).encode()})
if args.app_metrics:
    values = {}
    for service in ('auth', 'content', 'chat'):
        source = read_secret('dev', f'ureka-{service}-secrets') or {}
        value = base64.b64decode(source.get('INTERNAL_SERVICE_TOKEN', ''), validate=True)
        if not value or value.strip() != value or b'\n' in value or b'\r' in value:
            sys.exit('원본 내부 토큰이 없거나 잘못됐습니다. 값을 출력하지 않습니다.')
        values[service] = value
    existing = read_secret('observability', 'ureka-metrics-tokens')
    if existing is None:
        create('ureka-metrics-tokens', values)
    elif any(existing.get(k) != base64.b64encode(v).decode() for k, v in values.items()):
        sys.exit('관측 토큰과 원본 토큰이 다릅니다. 공동 회전 계획 후 갱신하세요. 덮어쓰지 않았습니다.')
print('관측 Secret 준비 완료 (기존 값 유지, 비밀값 출력 없음).')
