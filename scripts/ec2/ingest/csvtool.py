"""ingest-files Pod 안에서 쓰는 도구(EC2 dev ingest 수동 적재). 값(CSV 내용)은 출력하지 않는다.

ConfigMap ingest-tools로 /tools/csvtool.py에 붙는다. scripts/ec2/ingest.sh가 kubectl exec로 부른다.
  put <kind>        표준 입력을 /input/<파일>로 저장(임시 파일 → 이름 바꾸기). 바이트·sha256·CSV 행 수를 출력
  stat              /input의 CSV 3개 바이트·sha256·행 수
  pick <n>          공통 CSV에서 movie n/2·tv n/2개의 content_id(앞에서부터, 상세 행이 있는 것만)
  quarantine <job>  /output/<job>/quarantine.jsonl 요약(단계·오류 코드·HTTP 상태별 건수, 대표 오류 문장)
  report            DB 건수 확인(ingest-report Pod 안에서만: 작품·검색문서·임베딩·OTT·검색 가능·실행 기록)
kind: common | movie | tv. 파일 이름은 ingest(load_works.py)가 읽는 이름과 같아야 한다.
"""

from __future__ import annotations

import collections
import csv
import hashlib
import json
import os
import re
import sys
from pathlib import Path

FILES = {
    "common": "01_공통_common_staging_v0_0_21.csv",
    "movie": "02_movie_details_staging_v0_0_21.csv",
    "tv": "03_tv_series_details_staging_v0_0_21.csv",
}
INPUT = Path(os.environ.get("INGEST_INPUT_DIR", "/input"))
OUTPUT = Path(os.environ.get("INGEST_OUTPUT_DIR", "/output"))
MAX_BYTES = 1536 * 1024 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
JOB_RE = re.compile(r"^ingest-load-(sample|full)-[0-9]{8}-[0-9]{4}$")

csv.field_size_limit(64 * 1024 * 1024)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def count_rows(path: Path) -> int:
    # ingest와 같은 방식(utf-8-sig, csv 모듈)으로 센다. 칸 안 줄바꿈은 한 행으로 센다. 머리글 행은 빼고 센다.
    with path.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.reader(file)
        next(reader, None)
        return sum(1 for _ in reader)


def describe(path: Path) -> dict[str, object]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"file": path.name, "bytes": size, "sha256": digest.hexdigest(), "rows": count_rows(path)}


def put(kind: str) -> None:
    if kind not in FILES:
        fail("kind는 common·movie·tv 중 하나입니다")
    target = INPUT / FILES[kind]
    part = INPUT / f".{kind}.part"
    size = 0
    try:
        with part.open("wb") as out:
            for chunk in iter(lambda: sys.stdin.buffer.read(1024 * 1024), b""):
                size += len(chunk)
                if size > MAX_BYTES:
                    fail("파일이 너무 큽니다(1.5GiB 초과). 저장하지 않았습니다")
                out.write(chunk)
        if size == 0:
            fail("받은 내용이 없습니다. 저장하지 않았습니다")
        info = describe(part)
        os.replace(part, target)
    finally:
        part.unlink(missing_ok=True)
    info["file"] = target.name
    print(json.dumps(info, ensure_ascii=False))


def stat() -> None:
    missing = [name for name in FILES.values() if not (INPUT / name).is_file()]
    for name in FILES.values():
        if (INPUT / name).is_file():
            print(json.dumps(describe(INPUT / name), ensure_ascii=False))
    if missing:
        fail("없는 파일: " + ", ".join(missing))


def read_ids(path: Path) -> set[str]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        return {row.get("content_id", "") for row in csv.DictReader(file)}


def pick(n: int) -> None:
    if n < 2 or n > 500 or n % 2:
        fail("n은 2~500 사이 짝수입니다")
    details = {"movie": read_ids(INPUT / FILES["movie"]), "tv": read_ids(INPUT / FILES["tv"])}
    chosen: dict[str, list[str]] = {"movie": [], "tv": []}
    with (INPUT / FILES["common"]).open(encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            media_type = row.get("media_type", "")
            content_id = row.get("content_id", "")
            if media_type in chosen and len(chosen[media_type]) < n // 2 and UUID_RE.match(content_id):
                if content_id in details[media_type]:
                    chosen[media_type].append(content_id)
            if all(len(v) == n // 2 for v in chosen.values()):
                break
    if any(len(v) < n // 2 for v in chosen.values()):
        fail(f"고를 수 있는 작품이 모자랍니다: movie {len(chosen['movie'])}, tv {len(chosen['tv'])}")
    for content_id in chosen["movie"] + chosen["tv"]:
        print(content_id)


def quarantine(job: str) -> None:
    if not JOB_RE.match(job):
        fail("Job 이름 형식이 아닙니다(ingest-load-sample|full-YYYYMMDD-HHMM)")
    path = OUTPUT / job / "quarantine.jsonl"
    if not path.is_file():
        fail(f"{path}가 없습니다(Job이 아직 시작 전이거나 이름이 다름)")
    total = 0
    by_stage: collections.Counter[str] = collections.Counter()
    by_code: collections.Counter[str] = collections.Counter()
    by_error: collections.Counter[str] = collections.Counter()
    with path.open(encoding="utf-8") as file:
        for line in file:
            if not line.strip():
                continue
            total += 1
            record = json.loads(line)
            source = str(record.get("source", ""))
            stage = source.rsplit(":", 1)[1] if ":" in source else source
            by_stage[stage] += 1
            if record.get("error_code") or record.get("http_status"):
                by_code[f"{record.get('error_code')} HTTP {record.get('http_status')} 시도 {record.get('attempts')}"] += 1
            # 오류 문장에서 값이 바뀌는 부분(숫자·UUID)을 지워 종류별로 묶는다.
            message = re.sub(r"[0-9a-fA-F-]{36}|\d+", "#", str(record.get("error", "")))[:120]
            by_error[f"{stage} | {message}"] += 1
    print(f"격리 총 {total}건")
    print("단계별:", dict(by_stage))
    if by_code:
        print("임베딩 오류 코드별:", dict(by_code))
    print("오류 종류 상위 15:")
    for message, count in by_error.most_common(15):
        print(f"  {count:6d}  {message}")


REPORT_QUERIES = {
    "작품 수(유형별)": "SELECT media_type, content_type, count(*) FROM catalog.contents GROUP BY 1, 2 ORDER BY 1, 2",
    "검색문서 상태": "SELECT generation_status, count(*) FROM rag.content_search_documents GROUP BY 1 ORDER BY 1",
    "임베딩(활성 수 / 작품 수)": """SELECT (SELECT count(*) FROM rag.content_embeddings WHERE is_active AND status = 'completed'),
                                       (SELECT count(*) FROM catalog.contents)""",
    "OTT 현재 제공 작품(KR flatrate)": """SELECT count(DISTINCT content_id) FROM catalog.content_ott_availability
                                         WHERE is_available AND region = 'KR' AND offer_type = 'flatrate'""",
    "검색 가능 작품": "SELECT count(*) FROM catalog.contents WHERE is_searchable",
    "최근 실행 기록 10": """SELECT run_id, source, media_type, status, item_count, is_full_snapshot, completed_at,
                                  left(coalesce(failure_reason, ''), 100)
                           FROM ingest.ingestion_runs ORDER BY run_id DESC LIMIT 10""",
}


def report() -> None:
    import psycopg  # ingest 이미지에만 있다(ingest-report Pod)

    with psycopg.connect(os.environ["CONTENT_DB_DSN"]) as connection:
        for title, sql in REPORT_QUERIES.items():
            print(f"[{title}]")
            for row in connection.execute(sql).fetchall():
                print("  " + " | ".join("" if v is None else str(v) for v in row))


def main(argv: list[str]) -> None:
    if not argv:
        fail(__doc__ or "")
    command, rest = argv[0], argv[1:]
    if command == "put" and len(rest) == 1:
        put(rest[0])
    elif command == "stat" and not rest:
        stat()
    elif command == "pick" and len(rest) == 1 and rest[0].isdigit():
        pick(int(rest[0]))
    elif command == "quarantine" and len(rest) == 1:
        quarantine(rest[0])
    elif command == "report" and not rest:
        report()
    else:
        fail("사용법: put <common|movie|tv> | stat | pick <n> | quarantine <job> | report")


if __name__ == "__main__":
    main(sys.argv[1:])
