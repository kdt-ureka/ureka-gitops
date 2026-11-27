"""EKS 관측 설정(gitops#37 첫 단계) 오프라인 검사. helm과 PyYAML만 쓴다. 클러스터에 접근하지 않는다."""
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = 'charts/ureka-observability'
VALUES = 'environments/eks/observability/values.yaml'
EC2_VALUES = 'environments/ec2/observability/values.yaml'
APP = 'argocd/eks/observability-app.yaml'
STORAGE_DIR = 'environments/eks/observability/storageclass'
NAMESPACE = 'monitoring'
RESTRICTED = {f'pod-security.kubernetes.io/{k}': 'restricted' for k in ('enforce', 'audit', 'warn')}

def load(path):
    return yaml.safe_load((ROOT / path).read_text())

class EksObservability(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        out = subprocess.check_output(['helm', 'template', 'ureka-observability', CHART, '-n', NAMESPACE, '-f', VALUES], cwd=ROOT, text=True)
        cls.docs = [d for d in yaml.safe_load_all(out) if d]
        cls.app = load(APP)
        cls.storage = load(f'{STORAGE_DIR}/gp3.yaml')

    def kind(self, kind):
        return [d for d in self.docs if d['kind'] == kind]

    def test_app_is_manual_and_points_at_chart_values_and_storage(self):
        spec = self.app['spec']
        self.assertEqual(spec['project'], 'default')
        self.assertEqual(spec['destination'], {'server': 'https://kubernetes.default.svc', 'namespace': NAMESPACE})
        self.assertNotIn('automated', spec['syncPolicy'])
        self.assertEqual(spec['syncPolicy']['managedNamespaceMetadata']['labels'], RESTRICTED)
        chart, storage = spec['sources']
        self.assertEqual(chart['path'], CHART)
        for value_file in chart['helm']['valueFiles']:
            self.assertEqual((ROOT / CHART / value_file).resolve(), ROOT / VALUES)
        self.assertEqual(storage['path'], STORAGE_DIR)
        for source in spec['sources']:
            self.assertEqual(source['repoURL'], 'https://github.com/kdt-ureka/ureka-gitops.git')
            self.assertEqual(source['targetRevision'], 'main')
        # Argo CD는 이 폴더의 모든 yaml을 그대로 적용한다. StorageClass 하나만 있어야 한다.
        self.assertEqual([p.name for p in (ROOT / STORAGE_DIR).iterdir()], ['gp3.yaml'])

    def test_storage_class_is_encrypted_gp3_bound_after_scheduling(self):
        sc = self.storage
        self.assertEqual((sc['kind'], sc['provisioner']), ('StorageClass', 'ebs.csi.aws.com'))
        self.assertEqual(sc['parameters']['type'], 'gp3')
        self.assertEqual(sc['parameters']['encrypted'], 'true')
        self.assertEqual(sc['volumeBindingMode'], 'WaitForFirstConsumer')
        self.assertEqual(sc['reclaimPolicy'], 'Delete')
        self.assertNotIn('annotations', sc['metadata'])  # 클러스터 기본 클래스로 만들지 않는다.
        pvcs = self.kind('PersistentVolumeClaim')
        self.assertEqual(len(pvcs), 2)
        for pvc in pvcs:
            self.assertEqual(pvc['spec']['storageClassName'], sc['metadata']['name'])

    def test_app_metrics_off_touches_only_monitoring(self):
        for d in self.docs:
            self.assertIn(d['metadata'].get('namespace', NAMESPACE), (NAMESPACE,), d['metadata']['name'])
        self.assertFalse(self.kind('Role') + self.kind('RoleBinding') + self.kind('Secret') + self.kind('Ingress'))
        cfg = next(d for d in self.kind('ConfigMap') if d['metadata']['name'] == 'obs-prometheus')
        jobs = {j['job_name'] for j in yaml.safe_load(cfg['data']['prometheus.yml'])['scrape_configs']}
        self.assertEqual(jobs, {'prometheus', 'kube-state-metrics', 'kubelet-cadvisor'})
        for binding in self.kind('ClusterRoleBinding'):
            for subject in binding['subjects']:
                self.assertEqual(subject['namespace'], NAMESPACE)

    def test_images_and_resources_match_ec2(self):
        # 같은 승인 이미지·자원 예산(250m·1024Mi)을 쓴다. 한쪽만 올리면 여기서 걸린다.
        self.assertEqual(load(VALUES)['components'], load(EC2_VALUES)['components'])
        self.assertFalse(load(VALUES)['appMetrics']['enabled'])

if __name__ == '__main__':
    unittest.main()
