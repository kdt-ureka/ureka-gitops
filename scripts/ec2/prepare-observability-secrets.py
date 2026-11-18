#!/usr/bin/env python3
"""Prepare dedicated scrape credentials on the EC2 CN shell; never print values."""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--app-metrics', action='store_true')
parser.add_argument('--chat-metrics', action='store_true',
                    help='Only after chat supports dedicated scrape credentials.')
args = parser.parse_args()
if args.chat_metrics and not args.app_metrics:
    sys.exit('--chat-metrics에는 --app-metrics가 필요합니다.')
if os.geteuid() != 0 or not Path('/etc/rancher/k3s/k3s.yaml').is_file():
    sys.exit('EC2 k3s CN 셸에서 sudo로 실행하세요.')
os.environ['KUBECONFIG'] = '/etc/rancher/k3s/k3s.yaml'

def kube(*argv, data=None):
    p = subprocess.run(['kubectl', '--context', 'default', *argv], input=data,
                       text=True, capture_output=True)
    if p.returncode:
        sys.exit('Kubernetes 요청 실패. Secret 값은 출력하지 않습니다.')
    return p.stdout

def read_secret(namespace, name):
    raw = kube('-n', namespace, 'get', 'secret', name, '--ignore-not-found', '-o', 'json')
    try:
        return json.loads(raw).get('data', {}) if raw.strip() else None
    except (ValueError, AttributeError):
        sys.exit('Secret 응답 형식이 잘못됐습니다. 값을 출력하지 않습니다.')

def decode(data, key, required=True):
    try:
        value = base64.b64decode(data.get(key, ''), validate=True)
    except (ValueError, binascii.Error):
        sys.exit('토큰 형식이 잘못됐습니다. 값을 출력하지 않습니다.')
    if not value and not required:
        return None
    if not value or value.strip() != value or b'\n' in value or b'\r' in value:
        sys.exit('수집 토큰이 없거나 잘못됐습니다. 값을 출력하지 않습니다.')
    return value

def create(namespace, name, data):
    manifest = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                'metadata': {'name': name, 'namespace': namespace},
                'data': {k: base64.b64encode(v).decode() for k, v in data.items()}}
    kube('create', '-f', '-', data=json.dumps(manifest))

if args.app_metrics:
    services = ('auth', 'content', 'chat') if args.chat_metrics else ('auth', 'content')
    # 업무 토큰은 같지 않은지 비교만 한다. 관측 Secret에 복사하지 않는다.
    business_tokens = []
    for service in ('auth', 'content', 'chat'):
        data = read_secret('dev', f'ureka-{service}-secrets') or {}
        value = decode(data, 'INTERNAL_SERVICE_TOKEN', required=False)
        if value:
            business_tokens.append(value)
    values, pending = {}, []
    for service in services:
        name = f'ureka-{service}-metrics'
        existing = read_secret('dev', name)
        value = (decode(existing, 'METRICS_SCRAPE_TOKEN') if existing is not None
                 else secrets.token_urlsafe(32).encode())
        if value in business_tokens or value in values.values():
            sys.exit('수집 토큰은 업무 토큰 및 다른 서비스 수집 토큰과 달라야 합니다. 덮어쓰지 않았습니다.')
        values[service] = value
        if existing is None:
            pending.append((name, value))
    collector = read_secret('observability', 'ureka-metrics-tokens')
    if collector is not None and any(collector.get(k) != base64.b64encode(v).decode() for k, v in values.items()):
        sys.exit('관측 토큰과 서비스 수집 토큰이 다릅니다. 공동 회전 계획 후 갱신하세요. 덮어쓰지 않았습니다.')
    # 모든 검증 후에만 생성. 원본 업무 Secret과 기존 수집 Secret은 변경하지 않는다.
    for name, value in pending:
        create('dev', name, {'METRICS_SCRAPE_TOKEN': value})
    if collector is None:
        create('observability', 'ureka-metrics-tokens', values)

if read_secret('observability', 'ureka-grafana-admin') is None:
    create('observability', 'ureka-grafana-admin',
           {'admin-user': b'admin', 'admin-password': secrets.token_urlsafe(32).encode()})
print('관측 Secret 준비 완료 (기존 값 유지, 업무 토큰 복사 없음, 비밀값 출력 없음).')
