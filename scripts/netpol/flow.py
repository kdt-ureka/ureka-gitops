"""정책을 켠 뒤 사용자 흐름(가입 → 로그인 → 추천)이 프론트 입구 하나로 끝까지 되는지 본다(#40 완료 기준). 표준 라이브러리만.

사용: BASE_URL=http://127.0.0.1:8080 MAILPIT_URL=http://127.0.0.1:8025 python3 scripts/netpol/flow.py
- BASE_URL: 프론트 입구. kind는 `kubectl -n dev port-forward svc/ureka-frontend 8080:80`(프론트 Pod 앞 연결은 정책을 거치지 않는다),
  EC2는 SSM 터널 → Traefik(이 경우 Traefik → 프론트 정책까지 같이 확인된다).
- MAILPIT_URL: `kubectl -n dev port-forward deploy/mailpit 8025:8025`.
지나가는 연결: 프론트 → content·auth·chat·ops, auth → Mailpit·Redis·DB, chat → content·recommend·DB.
가입한 시험 계정은 남는다(dev 전용, 이메일 demo-netpol-<시각>@example.com).
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8080").rstrip("/")
MAILPIT = os.environ.get("MAILPIT_URL", "http://127.0.0.1:8025").rstrip("/")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
failed = 0


def call(method, path, body=None, token=None, key=False):
    headers = {}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if key:
        headers["Idempotency-Key"] = str(uuid.uuid4())
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw[:200].decode(errors="replace")}


def check(label, ok, detail=""):
    global failed
    print(f"{'PASS' if ok else 'FAIL'}  {label}  {detail}")
    if not ok:
        failed += 1
        print(f"\n중단: {label}. 결과 PASS 외 FAIL {failed}")
        sys.exit(1)


def mail_code(email):
    for _ in range(40):
        with opener.open(f"{MAILPIT}/api/v1/search?query={urllib.parse.quote('to:' + email)}", timeout=5) as r:
            messages = json.load(r).get("messages", [])
        if messages:
            with opener.open(f"{MAILPIT}/api/v1/message/{messages[0]['ID']}", timeout=5) as r:
                found = re.search(r"\b\d{6}\b", json.load(r).get("Text", ""))
            if found:
                return found.group()
        time.sleep(0.5)
    return None


# 1) 프론트 → content: 선택지
status, body = call("GET", "/api/content/v1/catalogs")
check("선택지 조회 (프론트 → content)", status == 200, f"{status}")
cat = body["data"]
available = {x["contentTypeId"] for x in cat["contentTypes"] if x["available"]}
genres = [g["id"] for g in cat["genres"] if g["contentTypeId"] in available][:3]
check("장르 3개 이상", len(genres) == 3, f"{genres}")

# 2) 가입: 프론트 → auth, auth → Mailpit(SMTP)·DB
stamp = str(int(time.time()))[-7:]
email, username, password = f"demo-netpol-{stamp}@example.com", f"np{stamp}", "abcde12345"
status, body = call("POST", "/api/auth/v1/email-verifications", {"email": email})
check("이메일 인증 요청 (auth → Mailpit)", status == 202, f"{status}")
vid = body["data"]["verificationId"]
code = mail_code(email)
check("Mailpit에서 인증 코드 받음", code is not None, email)
status, body = call("POST", f"/api/auth/v1/email-verifications/{vid}/confirmation", {"code": code})
check("인증 코드 확인", status == 200, f"{status}")
proof = body["data"]["emailVerificationToken"]
status, terms = call("GET", "/api/auth/v1/terms")
check("약관 조회", status == 200, f"{status}")
agreements = [{"termId": t["termId"], "agreed": True} for t in terms["data"]["items"] if t["required"]]
status, body = call("POST", "/api/auth/v1/users", {
    "username": username, "email": email, "password": password, "nickname": f"np{stamp}",
    "emailVerificationToken": proof, "agreements": agreements})
check("회원가입", status == 201, f"{status}")

# 3) 로그인: auth → Redis(리프레시 토큰)·DB
status, body = call("POST", "/api/auth/v1/login", {"loginId": username, "password": password})
check("로그인 (auth → Redis)", status == 200, f"{status}")
token = body["data"]["accessToken"]

# 4) 추천: 프론트 → chat, chat → content(선택지 확인)·recommend·DB
status, body = call("POST", "/api/chat/v1/personas", {"genreIds": genres}, token=token, key=True)
check("페르소나 만들기 (chat → content)", status == 201, f"{status}")
persona = body["data"].get("personaId") or body["data"].get("persona", {}).get("personaId")
check("페르소나 ID", bool(persona), f"{persona}")
status, body = call("POST", "/api/chat/v1/recommendations", {"genreIds": genres, "personaId": persona}, token=token, key=True)
rec = (body.get("data") or {}).get("recommendation") or {}
check("장르 추천 (chat → recommend → content)", status == 201,
      f"{status} items={len(rec.get('items', []))} shortage={rec.get('shortage')}")

# 5) 프론트 → ops: 관리 API까지 닿는지(관리자 토큰이 없어 401·403이 정상. 502·504면 연결이 막힌 것)
status, _ = call("GET", "/api/admin/v1/incidents", token=token)
check("관리 API 도달 (프론트 → ops)", status not in (502, 503, 504), f"{status}")

print("\n결과: 모두 PASS")
