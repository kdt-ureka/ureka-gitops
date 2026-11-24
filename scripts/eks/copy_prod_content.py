#!/usr/bin/env python3
"""Manual dev->prod data copy/verification; check is metadata-only, apply/verify create one temporary Job.
verify compares existing data/owned sequences without destination COPY, using a READ ONLY snapshot.
Reuse #95 identity/preflight, shared Lease and ownership-aware deletion. No values reach argv/logs.
"""
import argparse
import base64
import json
import os
import re
import signal
import sys
import time
import uuid

from operate import ROOT, SafeError
from bootstrap_prod_db import ProdDbBootstrap, RUN_LABEL, NS, interrupt

JOB = 'content-copy-prod'
CONFIGMAP = JOB
MASTER_SECRET = JOB + '-master'
DIRECTORY = ROOT / 'environments/eks/prod/content-copy'
JOB_FILE = DIRECTORY / 'job.yaml'
PAYLOADS = ('run-copy.sh', 'policy.sql', 'metadata.sql', 'empty.sql', 'report-hash.sql', 'validate.sql', 'numbers.sql', 'verify-hash.sql')
MAX_WAIT = 1260


def labels(run):
    return {'app.kubernetes.io/name': JOB, 'app.kubernetes.io/part-of': 'ureka', RUN_LABEL: run}


def manifest(host, run, verify_only=False):
    from bootstrap_prod_db import HOST_RE, PLACEHOLDER
    if not HOST_RE.fullmatch(host or '') or not re.fullmatch('[0-9a-f]{32}', run):
        raise SafeError('복사 Job 대상 또는 실행 표시 형식이 다릅니다(값은 출력하지 않음).')
    source = JOB_FILE.read_text()
    if source.count(PLACEHOLDER) != 1 or source.count(f'{RUN_LABEL}: RUN_ID\n') != 2:
        raise SafeError('복사 Job 템플릿의 자리표시가 다릅니다.')
    if verify_only:
        source = source.replace('command: ["/bin/bash", "/copy/run-copy.sh"]', 'command: ["/bin/bash", "/copy/run-copy.sh", "--verify-only"]')
    return source.replace(PLACEHOLDER, f'            - name: PGHOST\n              value: {host}\n').replace(
        f'{RUN_LABEL}: RUN_ID\n', f'{RUN_LABEL}: "{run}"\n')


def configmap(run):
    return json.dumps({'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {
        'name': CONFIGMAP, 'namespace': NS, 'labels': labels(run)},
        'data': {p: (DIRECTORY / p).read_text() for p in PAYLOADS}})


def secret(user, password, run):
    if not isinstance(user, str) or not user or not isinstance(password, str) or not password:
        raise SafeError('마스터 비밀의 username/password가 없습니다(값은 출력하지 않음).')
    return json.dumps({'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque', 'metadata': {
        'name': MASTER_SECRET, 'namespace': NS, 'labels': labels(run)},
        'data': {k: base64.b64encode(v.encode()).decode() for k, v in {'PGUSER': user, 'PGPASSWORD': password}.items()}})


def safe_log(raw):
    return '\n'.join(line for line in raw.splitlines() if re.fullmatch(
        r'copy (source|prod|ok|failed [1-6]|(contents|documents|embeddings|runs) [0-9 -]+)', line))


class Copy(ProdDbBootstrap):
    def pods_gone(self, run_id):
        selector = f'{RUN_LABEL}={run_id}' if run_id else f'job-name={JOB}'
        self.quiet(self.k('wait', '--for=delete', 'pod', '-l', selector, '--timeout=60s'), check=False)
        result = self.quiet(self.k('get', 'pod', '-l', selector, '-o', 'name'), check=False)
        return None if result.returncode else not result.stdout.strip()

    def cleanup(self, run_id):
        failed, foreign = [], []
        for kind, name in [('job', JOB), ('pods', None), ('secret', MASTER_SECRET), ('configmap', CONFIGMAP)]:
            if kind == 'pods':
                if self.pods_gone(run_id) is not True:
                    failed.append('copy Job Pod')
                continue
            result = self.delete_and_confirm(kind, name, run_id)
            if result == 'failed':
                failed.append(f'{kind}/{name}')
            elif result == 'foreign':
                foreign.append(f'{kind}/{name}')
        return failed, foreign

    def wait_job(self):
        deadline = time.monotonic() + self.args.max_wait
        while time.monotonic() < deadline:
            result = self.quiet(self.k('get', 'job', JOB, '-o', 'json'), check=False)
            if result.returncode:
                raise SafeError('복사 Job 상태 조회 실패(권한·연결).')
            status = json.loads(result.stdout).get('status', {})
            if status.get('succeeded') == 1:
                return 'ok'
            if status.get('failed'):
                return 'failed'
            time.sleep(self.args.poll)
        return 'timeout'

    def run_job(self, arn, host):
        master = self.read_secret(arn=arn)
        body = secret(master.get('username'), master.get('password'), self.run_id)
        master = None
        self.quiet(self.k('create', '-f', '-'), stdin=configmap(self.run_id))
        self.quiet(self.k('create', '-f', '-'), stdin=body)
        body = None
        self.quiet(self.k('create', '-f', '-'), stdin=manifest(host, self.run_id, verify_only=self.args.action == 'verify'))
        print('복사/대조 Job 실행 중. verify는 DB 대조만 하고 COPY하지 않습니다.', flush=True)
        state = self.wait_job()
        result = self.quiet(self.k('logs', 'job/' + JOB, '--tail=200'), check=False)
        summary = safe_log(result.stdout)
        if summary:
            print(summary)
        if state != 'ok' or result.returncode or not summary.endswith('copy ok'):
            raise SafeError('복사/대조 실패 또는 시간 초과. 출력된 단계 번호와 운영 문서를 확인하세요.')
        return 0

    def execute(self):
        if self.args.action in ('apply', 'verify') and self.args.confirm_env != NS:
            raise SafeError('실제 복사는 --confirm-env prod가 필요합니다.')
        if not 1 <= self.args.max_wait <= MAX_WAIT:
            raise SafeError('복사 대기는 1..1260초 범위입니다(공유 잠금 유효시간보다 짧게 유지).')
        self.preflight()
        arn, host = self.data_outputs()
        manifest(host, '0' * 32)
        configmap('0' * 32)
        if self.args.action == 'check':
            held = self.lease()
            print('설정 확인 완료(변경 없음). ' + ('공유 잠금 있음.' if held else '공유 잠금 없음.') +
                  ' 마스터 비밀·DB는 조회하지 않았습니다. Flyway/빈 표 검사는 apply Job 내부에서 수행합니다.')
            return 0
        self.run_id = uuid.uuid4().hex
        # Exactly the same db-bootstrap-prod-lock as #95, before any credential fetch or leftover cleanup.
        self.acquire_lock()
        pending = None
        residue, foreign = [], []
        lock_ok = False
        try:
            residue, _ = self.cleanup(None)
            if residue:
                raise SafeError('이전 복사 자원 정리 실패. 마스터 비밀을 읽지 않고 중단합니다.')
            self.run_job(arn, host)
        except BaseException as error:
            pending = error
        finally:
            previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
            try:
                if not residue:
                    try:
                        residue, foreign = self.cleanup(self.run_id)
                    except BaseException:
                        residue = ['copy cleanup status unknown']
                # Never release a shared lock if a credential-bearing copy Pod may still be active.
                if not residue and not foreign:
                    try:
                        lock_ok = self.release_lock()
                    except BaseException:
                        lock_ok = False
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
        if residue or foreign:
            print('정리 실패: 마스터 자격 또는 Job이 남았을 수 있습니다. 공유 Lease는 유지합니다. ' +
                  ', '.join(residue + foreign), file=sys.stderr)
            return 3
        if not lock_ok:
            print('공유 Lease 해제 실패. 다음 bootstrap/복사는 중단됩니다.', file=sys.stderr)
            return 1
        print('정리 확인: 복사 Job·Pod·임시 마스터 Secret·ConfigMap 없음.')
        if pending:
            raise pending
        return 0


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'apply', 'verify'))
    parser.add_argument('--profile', required=True)
    parser.add_argument('--context', default='ureka-eks')
    parser.add_argument('--cluster-name', default='ureka-eks')
    parser.add_argument('--confirm-env')
    parser.add_argument('--recover-stale-lock', action='store_true')
    parser.add_argument('--max-wait', type=int, default=MAX_WAIT, help=argparse.SUPPRESS)
    parser.add_argument('--poll', type=int, default=5, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        args.expected_account_id = os.environ.get('UREKA_EXPECTED_ACCOUNT_ID', '')
        if not re.fullmatch('[0-9]{12}', args.expected_account_id):
            raise SafeError('승인 계정 ID 환경 변수가 필요합니다(값은 출력하지 않음).')
        return Copy(args).execute()
    except SafeError as error:
        print('중단:', error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('중단 요청. 정리 확인 메시지와 공유 Lease 상태를 확인하세요.', file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
        print('중단: 접속·결과 형식 오류(원문은 출력하지 않음).', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
