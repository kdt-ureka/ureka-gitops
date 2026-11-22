"""check_eks_namespaces.py가 헛돌지 않는지 본다: 정상 입력은 통과, 값 하나씩 망가뜨리면 실패.

scripts/test-eks-namespaces.sh가 UREKA_NS_WORKDIR에 렌더링 결과를 넣고 실행한다.
"""

from __future__ import annotations

import copy
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import check_eks_namespaces as c

SRC = os.environ.get("UREKA_NS_WORKDIR")


@unittest.skipUnless(SRC, "UREKA_NS_WORKDIR가 없다(scripts/test-eks-namespaces.sh로 실행)")
class MutationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        for f in Path(SRC).glob("*.jsonl"):
            shutil.copy(f, self.tmp / f.name)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def run_check(self) -> list[str]:
        with redirect_stdout(io.StringIO()):
            return c.run(self.tmp)

    def mutate(self, name: str, fn) -> None:
        path = self.tmp / name
        objs = c.load(path)
        objs = fn(copy.deepcopy(objs))
        path.write_text("".join(json.dumps(o) + "\n" for o in objs))

    def assertFails(self, needle: str) -> None:
        errors = self.run_check()
        self.assertTrue(errors, "망가뜨린 입력이 통과했다")
        self.assertTrue(any(needle in e for e in errors), f"'{needle}' 오류가 없다: {errors}")

    @staticmethod
    def edit(kind: str, fn, name: str | None = None):
        def apply(objs):
            for o in objs:
                if o["kind"] == kind and (name is None or o["metadata"]["name"] == name):
                    fn(o)
            return objs
        return apply

    def test_baseline_passes(self):
        self.assertEqual(self.run_check(), [])

    def test_psa_warn_missing(self):
        self.mutate("prod-ns.jsonl", self.edit(
            "Namespace", lambda o: o["metadata"]["labels"].pop("pod-security.kubernetes.io/warn")))
        self.assertFails("Pod Security 라벨")

    def test_psa_baseline(self):
        self.mutate("dev-ns.jsonl", self.edit(
            "Namespace", lambda o: o["metadata"]["labels"].update({"pod-security.kubernetes.io/enforce": "baseline"})))
        self.assertFails("Pod Security 라벨")

    def test_prune_annotation_missing(self):
        self.mutate("prod-ns.jsonl", self.edit("Namespace", lambda o: o["metadata"].pop("annotations")))
        self.assertFails("Prune=false")

    def test_quota_memory_too_small_for_canary(self):
        self.mutate("prod-ns.jsonl", self.edit(
            "ResourceQuota", lambda o: o["spec"]["hard"].update({"requests.memory": "2816Mi"})))
        self.assertFails("requests.memory")

    def test_quota_pods_too_small(self):
        self.mutate("dev-ns.jsonl", self.edit("ResourceQuota", lambda o: o["spec"]["hard"].update({"pods": "9"})))
        self.assertFails("pods")

    def test_loadbalancer_allowed(self):
        self.mutate("prod-ns.jsonl", self.edit(
            "ResourceQuota", lambda o: o["spec"]["hard"].update({"services.loadbalancers": "1"})))
        self.assertFails("services.loadbalancers")

    def test_cluster_overcommit(self):
        self.mutate("dev-ns.jsonl", self.edit(
            "ResourceQuota", lambda o: o["spec"]["hard"].update({"requests.memory": "12Gi"})))
        self.assertFails("노드 용량")

    def test_container_over_limitrange_max(self):
        def big(o):
            o["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"] = "1536Mi"
        self.mutate("prod-workloads.jsonl", self.edit("Deployment", big, "ureka-content"))
        self.assertFails("LimitRange max")

    def test_limitrange_default_over_max(self):
        def bad(o):
            o["spec"]["limits"][0]["default"]["memory"] = "2Gi"
        self.mutate("dev-ns.jsonl", self.edit("LimitRange", bad))
        self.assertFails("default가 max")

    def test_missing_service(self):
        self.mutate("prod-workloads.jsonl", lambda objs: [
            o for o in objs if o["metadata"].get("name") != "ureka-frontend"])
        self.assertFails("서비스가 없다")

    def test_viewer_secrets(self):
        def add(o):
            o["rules"].append({"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]})
        self.mutate("prod-ns.jsonl", self.edit("Role", add, "prod-viewer"))
        self.assertFails("금지 자원")

    def test_viewer_logs(self):
        def add(o):
            o["rules"].append({"apiGroups": [""], "resources": ["pods/log"], "verbs": ["get"]})
        self.mutate("prod-ns.jsonl", self.edit("Role", add, "prod-viewer"))
        self.assertFails("pods/log")

    def test_viewer_write(self):
        def add(o):
            o["rules"][0]["verbs"].append("delete")
        self.mutate("prod-ns.jsonl", self.edit("Role", add, "prod-viewer"))
        self.assertFails("읽기 외 권한")

    def test_operator_any_rollout(self):
        self.mutate("prod-ns.jsonl", self.edit(
            "Role", lambda o: o["rules"][0].pop("resourceNames"), "prod-auth-rollout-operator"))
        self.assertFails("읽기 외 권한")

    def test_operator_update_verb(self):
        def add(o):
            o["rules"][0]["verbs"].append("update")
        self.mutate("prod-ns.jsonl", self.edit("Role", add, "prod-auth-rollout-operator"))
        self.assertFails("읽기 외 권한")

    def test_operator_update_deployments(self):
        def add(o):
            o["rules"].append({"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["patch"]})
        self.mutate("prod-ns.jsonl", self.edit("Role", add, "prod-auth-rollout-operator"))
        self.assertFails("읽기 외 권한")

    def test_operator_without_status_patch(self):
        def drop(o):
            o["rules"][0]["resources"] = ["rollouts"]
        self.mutate("prod-ns.jsonl", self.edit("Role", drop, "prod-auth-rollout-operator"))
        self.assertFails("rollouts/status patch")

    def test_cluster_role_binding(self):
        def add(objs):
            objs.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
                         "metadata": {"name": "x"}, "roleRef": {"kind": "ClusterRole", "name": "view"},
                         "subjects": [{"kind": "Group", "name": "ureka-prod-viewers"}]})
            return objs
        self.mutate("prod-ns.jsonl", add)
        self.assertFails("클러스터 범위")

    def test_system_group_name(self):
        def rename(o):
            o["subjects"][0]["name"] = "system:masters"
        self.mutate("prod-ns.jsonl", self.edit("RoleBinding", rename, "prod-viewers"))
        self.assertFails("system:")

    def test_rollout_renamed(self):
        self.mutate("prod-workloads.jsonl", self.edit(
            "Rollout", lambda o: o["metadata"].update({"name": "ureka-auth-v2"})))
        self.assertFails("resourceNames")


class QuantityTest(unittest.TestCase):
    def test_cpu(self):
        self.assertEqual(c.cpu_m("1"), 1000)
        self.assertEqual(c.cpu_m("1500m"), 1500)
        self.assertEqual(c.cpu_m("0.5"), 500)

    def test_mem(self):
        self.assertEqual(c.mem_mi("1Gi"), 1024)
        self.assertEqual(c.mem_mi("3584Mi"), 3584)
        self.assertEqual(c.mem_mi("1024Ki"), 1)

    def test_limitrange_defaults_apply(self):
        lr = {"defaultRequest": {"cpu": "50m", "memory": "64Mi"}, "default": {"cpu": "500m", "memory": "256Mi"}}
        self.assertEqual(c.container_resources({"name": "x"}, lr), (50, 64, 500, 256))
        # limit만 있으면 request = limit
        self.assertEqual(c.container_resources({"name": "x", "resources": {"limits": {"cpu": "200m", "memory": "100Mi"}}}, lr),
                         (200, 100, 200, 100))


if __name__ == "__main__":
    unittest.main()
