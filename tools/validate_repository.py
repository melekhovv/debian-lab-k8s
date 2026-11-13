"""Offline checks for lab manifest contracts and documentation links. No kubectl calls."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

import yaml

ROOT = Path(__file__).resolve().parents[1]


def manifest_errors(documents):
    errors = []
    objects = [doc for doc in documents if isinstance(doc, dict)]
    identities = [(doc.get('kind'), doc.get('metadata', {}).get('name')) for doc in objects]
    if len(identities) != len(set(identities)):
        errors.append('Duplicate Kubernetes object identity')
    deployments = [doc for doc in objects if doc.get('kind') == 'Deployment']
    services = [doc for doc in objects if doc.get('kind') == 'Service']
    if len(deployments) != 4 or len(services) != 4:
        errors.append('Expected four Deployments and four Services')
    if not any(doc.get('kind') == 'Namespace' and doc.get('metadata', {}).get('name') == 'debian-lab' for doc in objects):
        errors.append('Missing debian-lab Namespace')
    for doc in deployments + services:
        name = doc.get('metadata', {}).get('name', '<unnamed>')
        if doc.get('metadata', {}).get('namespace') != 'debian-lab':
            errors.append(f'{name}: namespace must be debian-lab')
    for dep in deployments:
        name = dep['metadata']['name']
        spec = dep.get('spec', {})
        template = spec.get('template', {})
        labels = template.get('metadata', {}).get('labels', {})
        selector = spec.get('selector', {}).get('matchLabels', {})
        if not selector or any(labels.get(k) != v for k, v in selector.items()):
            errors.append(f'{name}: Deployment selector does not match Pod labels')
        for container in template.get('spec', {}).get('containers', []):
            if not re.search(r'@sha256:[0-9a-f]{64}$', container.get('image', '')):
                errors.append(f'{name}: image must use a sha256 digest')
            resources = container.get('resources', {})
            for category in ('requests', 'limits'):
                if not all(resources.get(category, {}).get(key) for key in ('cpu', 'memory')):
                    errors.append(f'{name}: missing CPU/memory {category}')
    for service in services:
        name = service['metadata']['name']
        spec = service.get('spec', {})
        if spec.get('type', 'ClusterIP') != 'ClusterIP' or spec.get('externalIPs'):
            errors.append(f'{name}: external exposure is outside the current lab contract')
        selector = spec.get('selector', {})
        matches = [dep for dep in deployments if selector and all(
            dep.get('spec', {}).get('template', {}).get('metadata', {}).get('labels', {}).get(k) == v
            for k, v in selector.items())]
        if len(matches) != 1:
            errors.append(f'{name}: Service must select exactly one Deployment')
            continue
        ports = {p['containerPort'] for c in matches[0]['spec']['template']['spec']['containers'] for p in c.get('ports', [])}
        port_names = {p.get('name') for c in matches[0]['spec']['template']['spec']['containers'] for p in c.get('ports', [])}
        for port in spec.get('ports', []):
            target = port.get('targetPort', port.get('port'))
            if target not in ports and target not in port_names:
                errors.append(f'{name}: targetPort does not match a declared container port')
    return errors


def documentation_errors(root):
    errors = []
    paths = [root / 'README.md', root / 'README.en.md', *sorted((root / 'docs').rglob('*.md'))]
    for path in paths:
        text = path.read_text(encoding='utf-8')
        if sum(line.startswith('```') for line in text.splitlines()) % 2:
            errors.append(f'{path.name}: unclosed fenced block')
        # Ignore fenced examples; validate inline local links and image references.
        prose = re.sub(r'```.*?```', '', text, flags=re.S)
        for target in re.findall(r'\]\(([^)]+)\)', prose):
            parsed = urlsplit(target.strip('<>'))
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            if not (path.parent / unquote(parsed.path)).exists():
                errors.append(f'{path.relative_to(root)}: missing link target {target}')
    return errors


def main():
    documents = []
    try:
        for path in sorted((ROOT / 'k8s').glob('*.yaml')):
            documents.extend(yaml.safe_load_all(path.read_text(encoding='utf-8-sig')))
        errors = manifest_errors(documents) + documentation_errors(ROOT)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        print(f'Validation could not complete: {error}', file=sys.stderr)
        return 1
    for error in errors:
        print(f'FAIL: {error}', file=sys.stderr)
    if errors:
        return 1
    print('PASS: manifest contracts and local documentation links (offline only)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
