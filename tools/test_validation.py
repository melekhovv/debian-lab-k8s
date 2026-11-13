"""Regression checks: the validator must reject meaningful broken configurations."""
import copy
from pathlib import Path
import unittest

import yaml
from validate_repository import ROOT, manifest_errors


class ManifestValidationTests(unittest.TestCase):
    def setUp(self):
        self.documents = []
        for path in (ROOT / 'k8s').glob('*.yaml'):
            self.documents.extend(yaml.safe_load_all(path.read_text(encoding='utf-8-sig')))

    def mutate(self, kind):
        docs = copy.deepcopy(self.documents)
        return docs, next(doc for doc in docs if doc and doc.get('kind') == kind)

    def test_current_manifests(self):
        self.assertEqual(manifest_errors(self.documents), [])

    def test_service_with_wrong_selector_is_rejected(self):
        docs, service = self.mutate('Service')
        service['spec']['selector'] = {'app': 'missing'}
        self.assertTrue(any('select exactly one' in e for e in manifest_errors(docs)))

    def test_unpinned_image_is_rejected(self):
        docs, dep = self.mutate('Deployment')
        dep['spec']['template']['spec']['containers'][0]['image'] = 'example:latest'
        self.assertTrue(any('digest' in e for e in manifest_errors(docs)))

    def test_public_service_is_rejected(self):
        docs, service = self.mutate('Service')
        service['spec']['type'] = 'NodePort'
        self.assertTrue(any('external exposure' in e for e in manifest_errors(docs)))

    def test_wrong_target_port_is_rejected(self):
        docs, service = self.mutate('Service')
        service['spec']['ports'][0]['targetPort'] = 9999
        self.assertTrue(any('targetPort' in e for e in manifest_errors(docs)))

    def test_missing_resource_limit_is_rejected(self):
        docs, dep = self.mutate('Deployment')
        del dep['spec']['template']['spec']['containers'][0]['resources']['limits']['memory']
        self.assertTrue(any('missing CPU/memory limits' in e for e in manifest_errors(docs)))


if __name__ == '__main__':
    unittest.main()
