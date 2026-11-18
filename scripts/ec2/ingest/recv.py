"""원본 CSV를 내 PC에서 EC2로 받는 임시 수신기(EC2 dev ingest 수동 적재). scripts/ec2/ingest.sh recv가 root로 실행한다.

- 127.0.0.1에만 열린다. 내 PC는 SSM 포트 포워딩(AWS-StartPortForwardingSession)으로만 닿는다. 보안 그룹·공인 포트를 열지 않는다.
- PUT /common, /movie, /tv 세 경로만 받는다(파일 이름은 이 스크립트가 정한다. 요청이 경로를 정하지 못한다).
- 저장: <dest>/<파일>(폴더 0700, 파일 0600). 임시 파일에 쓴 뒤 다 받았을 때만 이름을 바꾼다.
- 응답과 화면에는 바이트 수·sha256만 낸다. CSV 내용은 출력하지 않는다.
- 세 파일을 다 받으면 스스로 끝난다(Ctrl+C로도 끝난다).
"""

from __future__ import annotations

import hashlib
import http.server
import os
import sys
from pathlib import Path

FILES = {
    "common": "01_공통_common_staging_v0_0_21.csv",
    "movie": "02_movie_details_staging_v0_0_21.csv",
    "tv": "03_tv_series_details_staging_v0_0_21.csv",
}
MAX_BYTES = 1536 * 1024 * 1024
received: set[str] = set()


class Handler(http.server.BaseHTTPRequestHandler):
    dest: Path
    # 연결 소켓 읽기 시간 제한(초). 멈춘 연결이 다음 업로드를 계속 막지 않게 한다.
    # 넘으면 그 요청은 실패하고 임시 파일을 지운 뒤 다음 연결을 받는다.
    timeout = float(os.environ.get("INGEST_RECV_TIMEOUT_SECONDS", "120"))

    def _reply(self, status: int, text: str) -> None:
        body = (text + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self) -> None:  # noqa: N802 (http.server 규칙)
        kind = self.path.strip("/")
        if kind not in FILES:
            self._reply(404, "경로는 /common, /movie, /tv 중 하나입니다")
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._reply(411, "Content-Length가 필요합니다(curl -T 사용)")
            return
        if length <= 0 or length > MAX_BYTES:
            self._reply(413, "크기가 0이거나 1.5GiB를 넘습니다")
            return
        target = self.dest / FILES[kind]
        part = self.dest / f".{kind}.part"
        digest = hashlib.sha256()
        remaining = length
        try:
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as out:
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        break
                    digest.update(chunk)
                    out.write(chunk)
                    remaining -= len(chunk)
            if remaining:
                self._reply(400, f"전송이 중간에 끊겼습니다({length - remaining}/{length}바이트). 다시 보내세요")
                return
            os.replace(part, target)
        finally:
            part.unlink(missing_ok=True)
        received.add(kind)
        line = f"{kind} {target.name} {length}바이트 sha256 {digest.hexdigest()}"
        print("받음:", line, flush=True)
        self._reply(200, line)

    def log_message(self, format: str, *args: object) -> None:  # 요청 줄 대신 위 한 줄만 남긴다
        return

    def log_error(self, format: str, *args: object) -> None:
        # 읽기 시간 초과 등(http.server가 연결을 닫는다). 요청 내용은 출력하지 않는다.
        print("연결 하나가 실패했습니다(시간 초과 또는 끊김). 그 파일을 다시 보내세요.", file=sys.stderr, flush=True)


class Server(http.server.HTTPServer):
    def handle_error(self, request: object, client_address: object) -> None:
        # 시간 초과·끊긴 연결: 그 요청만 버리고 계속 받는다(요청 내용은 출력하지 않음).
        print("연결 하나가 실패했습니다(시간 초과 또는 끊김). 그 파일을 다시 보내세요.", file=sys.stderr, flush=True)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("사용법: recv.py <받을 폴더> <포트>")
    dest, port = Path(sys.argv[1]), int(sys.argv[2])
    dest.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(dest, 0o700)
    Handler.dest = dest
    server = Server(("127.0.0.1", port), Handler)
    print(f"127.0.0.1:{port}에서 기다립니다. 세 파일을 다 받으면 끝납니다(Ctrl+C로 중단).", flush=True)
    try:
        while received != set(FILES):
            server.handle_request()
    except KeyboardInterrupt:
        print("\n중단했습니다.", flush=True)
    finally:
        server.server_close()
    print("받은 파일:", ", ".join(sorted(received)) or "없음", flush=True)


if __name__ == "__main__":
    main()
