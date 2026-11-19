"""scripts/netpol/probe.sh 결과를 허용 표와 비교한다. 표준 라이브러리만.

사용: python3 probe_compare.py <expected.json> <시나리오> "<받는쪽:포트 ...>" <결과 파일> <실행 실패 수>
결과 파일 한 줄: "<보내는 쪽> <받는 쪽>:<포트> <허용|차단> [이유]"

성공 조건(하나라도 어기면 실패):
- 실행 실패(exec·Pod 재시작 등)가 0건
- 결과 행 집합 = 표의 모든 보내는 쪽 × 요청한 받는 쪽:포트 (빠진 행·중복 행·모르는 행 없음, 0건이면 실패)
- 요청한 받는 쪽:포트마다 이 시나리오에서 허용인 보내는 쪽이 하나 이상 있어야 한다
  (허용 연결이 실제로 성공해야 리스너가 살아 있다고 볼 수 있다. 서비스가 죽어서 생긴 '차단'을 성공으로 읽지 않는다)
- 각 행의 결과가 표와 같다
"""
import json
import sys


def compare(exp, scenario, targets, lines, exec_failures):
    errors = []
    keys = list(exp["allow"])
    if scenario not in keys:
        return [f"시나리오가 없다: {scenario}"], []
    allow = set()
    for s in keys[: keys.index(scenario) + 1]:
        allow |= {tuple(x) for x in exp["allow"][s]}
    if exec_failures:
        errors.append(f"시험 Pod 실행 실패 {exec_failures}건(결과를 믿을 수 없다)")

    wanted_targets = []
    for t in targets:
        name, _, port = t.partition(":")
        if name not in exp["targets"] or not port.isdigit() or int(port) not in exp["targets"][name]:
            errors.append(f"표에 없는 받는 쪽:포트를 요청했다: {t}")
            continue
        wanted_targets.append((name, int(port)))
    if not wanted_targets:
        errors.append("요청한 받는 쪽이 없다")
    for name, port in wanted_targets:
        if not any((src, name, port) in allow for src in exp["sources"]):
            errors.append(f"{name}:{port}는 이 시나리오에서 허용인 보내는 쪽이 없어 리스너가 살아 있는지 확인할 수 없다(대상에서 빼거나 시나리오를 바꾼다)")

    required = {(src, name, port) for src in exp["sources"] for name, port in wanted_targets}
    seen, rows = set(), []
    for raw in lines:
        parts = raw.split()
        if not parts:
            continue
        if len(parts) < 3 or ":" not in parts[1] or parts[2] not in ("허용", "차단"):
            errors.append(f"알 수 없는 결과 행: {raw.strip()}")
            continue
        src, target, got, why = parts[0], parts[1], parts[2], " ".join(parts[3:])
        name, _, port = target.partition(":")
        key = (src, name, int(port) if port.isdigit() else port)
        if key not in required:
            errors.append(f"요청하지 않은 조합의 결과: {raw.strip()}")
            continue
        if key in seen:
            errors.append(f"중복 결과: {raw.strip()}")
            continue
        seen.add(key)
        want = "허용" if key in allow else "차단"
        if got != want:
            errors.append(f"{src} → {target} 표={want}, 실제={got} {why}".strip())
        rows.append((src, target, want, got, why))
    for key in sorted(required - seen):
        errors.append(f"결과 없음: {key[0]} → {key[1]}:{key[2]}")
    return errors, sorted(rows)


def main():
    exp_path, scenario, targets, results, exec_failures = sys.argv[1:]
    exp = json.load(open(exp_path, encoding="utf-8"))
    lines = open(results, encoding="utf-8").read().splitlines()
    errors, rows = compare(exp, scenario, targets.split(), lines, int(exec_failures))
    print("| 보내는 쪽 | 받는 쪽:포트 | 표 | 실제 |\n|---|---|---|---|")
    for src, target, want, got, why in rows:
        mark = "" if want == got else "  ← 다름"
        print(f"| {src} | {target} | {want} | {got}{(' (' + why + ')') if why else ''}{mark} |")
    for e in errors:
        print(f"::error::{e}")
    print(f"\n조합 {len(rows)}개 받음, 문제 {len(errors)}개 (시나리오: {scenario})")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
