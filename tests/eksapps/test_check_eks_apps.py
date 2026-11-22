"""check_eks_apps.py 자체 시험: 실제 렌더 결과는 통과하고, 값 하나씩 망가뜨리면 실패해야 한다.
scripts/check-charts.sh가 UREKA_EKS_APPS_WORKDIR(렌더 결과 폴더)를 넘겨 실행한다."""
import copy
import importlib.util
import os
from pathlib import Path
import unittest

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_eks_apps", here / "check_eks_apps.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
WORK = os.environ.get("UREKA_EKS_APPS_WORKDIR")


@unittest.skipUnless(WORK, "scripts/check-charts.sh에서 실행한다(렌더 결과 필요)")
class Mutations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        w = Path(WORK)
        cls.apps = m.load(w / "apps.jsonl")
        cls.svc = {e: m.load(w / f"{e}-svc.jsonl") for e in m.ENVS}
        cls.data = {e: m.load(w / f"{e}-data.jsonl") for e in m.ENVS}
        cls.ns = {e: m.load(w / f"{e}-namespace.jsonl") for e in m.ENVS}

    def apps_copy(self):
        return copy.deepcopy(self.apps)

    def obj(self, objs, kind, name):
        return next(o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name)

    def env_item(self, objs, workload, name):
        for o in m.workloads(objs):
            if o["metadata"]["name"] == workload:
                for e in o["spec"]["template"]["spec"]["containers"][0]["env"]:
                    if e["name"] == name:
                        return e
        raise KeyError(name)

    # 기준: 실제 결과는 통과
    def test_real_inputs_pass(self):
        self.assertEqual(m.check_projects(self.apps), [])
        self.assertEqual(m.check_applications(self.apps), [])
        for e in m.ENVS:
            self.assertEqual(m.check_env_values(e, self.svc[e]), [])
            self.assertEqual(m.check_shape(e, self.svc[e]), [])

    # AppProject
    def test_env_project_allowing_secret_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-prod")["spec"]["namespaceResourceWhitelist"].append({"group": "", "kind": "Secret"})
        self.assertTrue(m.check_projects(apps))

    def test_env_project_with_cluster_resources_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-dev")["spec"]["clusterResourceWhitelist"] = [{"group": "", "kind": "Namespace"}]
        self.assertTrue(m.check_projects(apps))

    def test_dev_project_reaching_prod_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-dev")["spec"]["destinations"].append(
            {"server": m.SERVER, "namespace": "prod"})
        self.assertTrue(m.check_projects(apps))

    def test_wildcard_destination_or_repo_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-platform")["spec"]["destinations"][0]["namespace"] = "*"
        self.assertTrue(m.check_projects(apps))
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-dev")["spec"]["sourceRepos"] = ["*"]
        self.assertTrue(m.check_projects(apps))

    def test_platform_namespace_name_restricted(self):
        def cluster(apps):
            return self.obj(apps, "AppProject", "ureka-eks-platform")["spec"]["clusterResourceWhitelist"]
        apps = self.apps_copy()
        cluster(apps)[0].pop("name")  # name 누락 = 모든 Namespace
        self.assertTrue(m.check_projects(apps))
        apps = self.apps_copy()
        cluster(apps)[0]["name"] = "*"
        self.assertTrue(m.check_projects(apps))
        apps = self.apps_copy()
        cluster(apps).append({"group": "", "kind": "Namespace", "name": "argocd"})
        self.assertTrue(m.check_projects(apps))
        apps = self.apps_copy()
        cluster(apps).pop()  # prod 빠짐
        self.assertTrue(m.check_projects(apps))

    def test_namespace_object_must_match_allowed_name(self):
        ns = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "argocd"}}]
        self.assertTrue(m.check_kinds(self.apps, {("namespace", "dev"): ns}))
        ok = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "dev"}}]
        self.assertEqual(m.check_kinds(self.apps, {("namespace", "dev"): ok}), [])

    def test_platform_extra_cluster_kind_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "AppProject", "ureka-eks-platform")["spec"]["clusterResourceWhitelist"].append(
            {"group": "rbac.authorization.k8s.io", "kind": "ClusterRoleBinding"})
        self.assertTrue(m.check_projects(apps))

    def test_prod_role_beyond_rollout_actions_fails(self):
        for bad in ("p, proj:ureka-eks-prod:auth-rollout-operator, applications, sync, ureka-eks-prod/ureka-auth-eks-prod, allow",
                    "p, proj:ureka-eks-prod:auth-rollout-operator, applications, action/argoproj.io/Rollout/resume, ureka-eks-prod/*, allow",
                    "p, proj:ureka-eks-prod:auth-rollout-operator, logs, get, ureka-eks-prod/ureka-auth-eks-prod, allow"):
            apps = self.apps_copy()
            self.obj(apps, "AppProject", "ureka-eks-prod")["spec"]["roles"][0]["policies"].append(bad)
            self.assertTrue(m.check_projects(apps), bad)

    def test_role_in_dev_project_fails(self):
        apps = self.apps_copy()
        role = copy.deepcopy(self.obj(apps, "AppProject", "ureka-eks-prod")["spec"]["roles"][0])
        self.obj(apps, "AppProject", "ureka-eks-dev")["spec"]["roles"] = [role]
        self.assertTrue(m.check_projects(apps))

    # Application
    def test_prod_auto_sync_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-auth-eks-prod")["spec"]["syncPolicy"]["automated"] = {"prune": True, "selfHeal": True}
        self.assertTrue(m.check_applications(apps))

    def test_dev_without_auto_sync_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-chat-eks-dev")["spec"]["syncPolicy"].pop("automated")
        self.assertTrue(m.check_applications(apps))

    def test_prod_namespace_app_must_stay_auto(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-eks-namespace-prod")["spec"]["syncPolicy"].pop("automated")
        self.assertTrue(m.check_applications(apps))

    def test_service_in_platform_project_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-ops-eks-dev")["spec"]["project"] = "ureka-eks-platform"
        self.assertTrue(m.check_applications(apps))

    def test_prod_app_with_dev_values_fails(self):
        apps = self.apps_copy()
        src = self.obj(apps, "Application", "ureka-auth-eks-prod")["spec"]["sources"][0]
        src["helm"]["valueFiles"][1] = "../../environments/eks/dev/ureka-auth.yaml"
        self.assertTrue(m.check_applications(apps))

    def test_prod_app_to_dev_namespace_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-eks-data-prod")["spec"]["destination"]["namespace"] = "dev"
        self.assertTrue(m.check_applications(apps))

    def test_other_branch_fails(self):
        apps = self.apps_copy()
        self.obj(apps, "Application", "ureka-frontend-eks-prod")["spec"]["sources"][0]["targetRevision"] = "feature"
        self.assertTrue(m.check_applications(apps))

    # 종류
    def test_ingress_not_whitelisted_yet(self):
        svc = copy.deepcopy(self.svc["prod"])
        svc.append({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": {"name": "x"}})
        self.assertTrue(m.check_kinds(self.apps, {("service", "prod"): svc}))

    def test_loadbalancer_service_fails(self):
        data = copy.deepcopy(self.data["dev"])
        self.obj(data, "Service", "redis")["spec"]["type"] = "LoadBalancer"
        self.assertTrue(m.check_kinds(self.apps, {("data", "dev"): data}))

    def test_resource_in_other_namespace_fails(self):
        data = copy.deepcopy(self.data["prod"])
        self.obj(data, "Deployment", "redis")["metadata"]["namespace"] = "dev"
        self.assertTrue(m.check_kinds(self.apps, {("data", "prod"): data}))

    # prod/dev 분리·비밀
    def test_prod_with_dev_db_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.env_item(svc, "ureka-content", "DB_URL")["value"] = "jdbc:postgresql://postgres:5432/content_db"
        self.assertTrue(m.check_env_values("prod", svc))

    def test_prod_with_dev_user_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.env_item(svc, "ureka-ops", "DB_USERNAME")["value"] = "ops_db_app"
        self.assertTrue(m.check_env_values("prod", svc))

    def test_prod_chat_worker_dev_url_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.env_item(svc, "ureka-chat-worker", "DATABASE_URL")["value"] = \
            "postgresql+psycopg://chat_db_app:$(DB_PASSWORD)@postgres:5432/chat_db"
        self.assertTrue(m.check_env_values("prod", svc))

    def test_dev_with_prod_db_fails(self):
        svc = copy.deepcopy(self.svc["dev"])
        self.env_item(svc, "ureka-auth", "DB_URL")["value"] = "jdbc:postgresql://postgres:5432/auth_db_prod"
        self.assertTrue(m.check_env_values("dev", svc))

    def test_prod_frontend_to_dev_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.env_item(svc, "ureka-frontend", "AUTH_UPSTREAM")["value"] = "http://ureka-auth.dev.svc.cluster.local"
        self.assertTrue(m.check_env_values("prod", svc))

    def test_plain_secret_value_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        item = self.env_item(svc, "ureka-auth", "JWT_PRIVATE_KEY")
        item.pop("valueFrom")
        item["value"] = "plain"
        self.assertTrue(m.check_env_values("prod", svc))

    def test_prod_cookie_insecure_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.env_item(svc, "ureka-auth", "COOKIE_SECURE")["value"] = "false"
        self.assertTrue(m.check_env_values("prod", svc))

    # 모양
    def test_dev_two_replicas_fails(self):
        svc = copy.deepcopy(self.svc["dev"])
        self.obj(svc, "Deployment", "ureka-content")["spec"]["replicas"] = 2
        self.assertTrue(m.check_shape("dev", svc))

    def test_auth_deployment_or_cpu_fails(self):
        svc = copy.deepcopy(self.svc["prod"])
        self.obj(svc, "Rollout", "ureka-auth")["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]["cpu"] = "120m"
        self.assertTrue(m.check_shape("prod", svc))
        svc = copy.deepcopy(self.svc["dev"])
        self.obj(svc, "Rollout", "ureka-auth")["kind"] = "Deployment"
        self.assertTrue(m.check_shape("dev", svc))

    def test_surge_counts_rolling_update(self):
        d = {"kind": "Deployment", "spec": {"replicas": 1}}
        self.assertEqual(m.surge(d), 1)
        self.assertEqual(m.surge({"kind": "Deployment", "spec": {"replicas": 2, "strategy": {"type": "Recreate"}}}), 0)
        self.assertEqual(m.surge({"kind": "Rollout", "spec": {"replicas": 2}}), 1)

    # Quota (#62 네임스페이스가 있을 때)
    def test_quota_exceeded_fails(self):
        for env in m.ENVS:
            if self.ns[env] is None:
                self.skipTest("#62 네임스페이스 없음")
            ns = copy.deepcopy(self.ns[env])
            self.obj(ns, "ResourceQuota", f"{env}-quota")["spec"]["hard"]["requests.cpu"] = "100m"
            self.assertTrue(m.check_quota(env, self.svc[env], self.data[env], ns))


if __name__ == "__main__":
    unittest.main()
