"""check_matrix.py(정책 계산)와 probe_compare.py(실측 결과 비교) 단위 시험. 표준 라이브러리만.
실행: python3 -m unittest discover -s tests/networkpolicy -p 'test_*.py'
"""
import json
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_matrix as cm  # noqa: E402
import probe_compare as pc  # noqa: E402

DEV_A = {"namespace": "dev", "labels": {"app.kubernetes.io/name": "a"}}
DEV_B = {"namespace": "dev", "labels": {"app.kubernetes.io/name": "b"}}
OTHER_A = {"namespace": "other", "labels": {"app.kubernetes.io/name": "a"}}
TARGET = {"app.kubernetes.io/name": "t"}


def pol(ingress, selector=None, types=("Ingress",)):
    return {"kind": "NetworkPolicy", "metadata": {"name": "p", "namespace": "dev"},
            "spec": {"podSelector": selector if selector is not None else {"matchLabels": TARGET},
                     "policyTypes": list(types), "ingress": ingress}}


def ns(name):
    return {"matchLabels": {"kubernetes.io/metadata.name": name}}


class Semantics(unittest.TestCase):
    """NetworkPolicy 의미(공식 문서 기준)를 작은 입력으로 하나씩 본다."""

    def allowed(self, policies, src, port=80):
        cm.validate(policies)
        return cm.allowed(policies, src, TARGET, port)

    def test_cases(self):
        a_only = {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "a"}}}
        cases = [
            # (설명, 정책, 출발지, 포트, 기대)
            ("정책 없음 → 모두 허용", [], OTHER_A, 80, True),
            ("기본 거부 ingress [] → 차단", [pol([], selector={})], DEV_A, 80, False),
            ("from 생략 → 모든 출발지", [pol([{"ports": [{"port": 80}]}])], OTHER_A, 80, True),
            ("from [] → 모든 출발지", [pol([{"from": [], "ports": [{"port": 80}]}])], OTHER_A, 80, True),
            ("ports 생략 → 모든 포트", [pol([{"from": [a_only]}])], DEV_A, 9999, True),
            ("podSelector만 → 같은 네임스페이스만", [pol([{"from": [a_only]}])], OTHER_A, 80, False),
            ("podSelector {} → 같은 네임스페이스 모든 Pod", [pol([{"from": [{"podSelector": {}}]}])], DEV_B, 80, True),
            ("podSelector {}는 다른 네임스페이스 아님", [pol([{"from": [{"podSelector": {}}]}])], OTHER_A, 80, False),
            ("namespaceSelector {} → 모든 네임스페이스", [pol([{"from": [{"namespaceSelector": {}}]}])], OTHER_A, 80, True),
            ("ns AND pod 한 항목: 둘 다 맞아야", [pol([{"from": [{"namespaceSelector": ns("other"), **a_only}]}])], DEV_A, 80, False),
            ("ns AND pod 한 항목: 맞음", [pol([{"from": [{"namespaceSelector": ns("other"), **a_only}]}])], OTHER_A, 80, True),
            ("ns, pod 두 항목(OR): 하나만 맞아도", [pol([{"from": [{"namespaceSelector": ns("other")}, a_only]}])], DEV_A, 80, True),
            ("포트 다르면 차단", [pol([{"from": [a_only], "ports": [{"port": 81}]}])], DEV_A, 80, False),
            ("UDP 포트는 TCP 허용 아님", [pol([{"from": [a_only], "ports": [{"protocol": "UDP", "port": 80}]}])], DEV_A, 80, False),
            ("Egress 전용 정책은 ingress를 격리하지 않음", [pol([], selector={}, types=("Egress",))], OTHER_A, 80, True),
            ("정책 합집합", [pol([], selector={}), pol([{"from": [a_only]}])], DEV_A, 80, True),
        ]
        for label, policies, src, port, want in cases:
            with self.subTest(label):
                self.assertEqual(self.allowed(policies, src, port), want)

    def test_unsupported_rejected_before_compare(self):
        bad = [
            ("빈 peer", pol([{"from": [{}]}])),
            ("ipBlock", pol([{"from": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}])),
            ("matchExpressions", pol([{"from": [{"podSelector": {"matchExpressions": []}}]}])),
            ("이름 포트", pol([{"from": [{"podSelector": {}}], "ports": [{"port": "http"}]}])),
            ("endPort", pol([{"from": [{"podSelector": {}}], "ports": [{"port": 80, "endPort": 90}]}])),
        ]
        for label, p in bad:
            with self.subTest(label):
                # 아무 Pod도 고르지 않는 정책이어도 사전 검사에서 걸려야 한다.
                p["spec"]["podSelector"] = {"matchLabels": {"app.kubernetes.io/name": "없음"}}
                with self.assertRaises(cm.Unsupported):
                    cm.validate([p])


class ProbeCompare(unittest.TestCase):
    exp = json.loads((HERE / "expected.json").read_text(encoding="utf-8"))
    scenario = "기본(관측 꺼짐)"
    targets = ["ureka-auth:8080", "redis:6379"]

    def good_lines(self):
        allow = {tuple(x) for x in self.exp["allow"][self.scenario]}
        lines = []
        for src in self.exp["sources"]:
            for t in self.targets:
                name, port = t.split(":")
                lines.append(f"{src} {t} {'허용' if (src, name, int(port)) in allow else '차단 TimeoutError'}")
        return lines

    def run_compare(self, lines, failures=0, targets=None):
        errors, _ = pc.compare(self.exp, self.scenario, targets or self.targets, lines, failures)
        return errors

    def test_complete_matching_result_passes(self):
        self.assertEqual(self.run_compare(self.good_lines()), [])

    def test_failures(self):
        good = self.good_lines()
        flipped = good[:]
        flipped[0] = flipped[0].replace("차단 TimeoutError", "허용") if "차단" in flipped[0] else flipped[0].replace("허용", "차단 TimeoutError")
        cases = [
            ("빈 결과", [], 0, None),
            ("한 행 빠짐", good[1:], 0, None),
            ("중복 행", good + good[:1], 0, None),
            ("모르는 보내는 쪽", good + ["dev/모름 ureka-auth:8080 허용"], 0, None),
            ("요청 안 한 대상", good + [good[0].replace("ureka-auth:8080", "ureka-ops:8080")], 0, None),
            ("깨진 행", good + ["엉망"], 0, None),
            ("실행 실패", good, 1, None),
            ("결과가 표와 다름", flipped, 0, None),
            ("허용 출발지 없는 대상(리스너 확인 불가)", good, 0, self.targets + ["ureka-auth:9091"]),
            ("표에 없는 대상", good, 0, self.targets + ["없음:1"]),
            ("대상 0개", [], 0, ["x"]),
        ]
        for label, lines, failures, targets in cases:
            with self.subTest(label):
                self.assertNotEqual(self.run_compare(lines, failures, targets), [])


if __name__ == "__main__":
    unittest.main()
