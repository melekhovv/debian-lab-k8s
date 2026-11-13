"""Observe the existing lab; never apply manifests, restore data or start services.

Optional routing probes open six short TCP connections to lab port 9.
Reports contain runtime metadata: review before publishing.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys

MACHINES = ['debian-desktop', 'debian-client-1', 'debian-client-2', 'debian-client-3']


def execute(command, timeout=20):
    try:
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
        return {'command': command, 'exit_code': result.returncode,
                'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': command, 'exit_code': 1, 'stdout': '', 'stderr': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', default='minikube')
    parser.add_argument('--output', type=Path, help='Local JSON output; never uploaded automatically')
    parser.add_argument('--probe-routing', action='store_true', help='Send six bounded TCP probes; this is active traffic')
    args = parser.parse_args()
    executable = shutil.which('kubectl')
    if not executable:
        print('kubectl not found', file=sys.stderr)
        return 1
    prefix = [executable, '--context', args.context, '--request-timeout=10s', '-n', 'debian-lab']
    report = {'timestamp_utc': datetime.now(timezone.utc).isoformat(), 'context': args.context,
              'scope': 'observation; no cluster configuration changes', 'checks': [], 'routing': []}

    def check(label, command):
        result = execute(command)
        result['label'] = label
        report['checks'].append(result)
        print(('PASS' if result['exit_code'] == 0 else 'FAIL') + ': ' + label)
        return result

    inventory = check('Kubernetes inventory', prefix + ['get', 'pods,deployments,services', '-o', 'json'])
    if inventory['exit_code'] == 0:
        pod_check = "import socket; s=socket.create_connection(('127.0.0.1',3000),3); s.close(); print('GUI TCP listener reachable')"
        for name in MACHINES:
            target = ['exec', 'deployment/' + name, '--']
            check(name + ': addresses', prefix + target + ['ip', '-4', 'addr', 'show', 'dev', 'eth0'])
            check(name + ': routes', prefix + target + ['ip', '-4', 'route', 'show'])
            check(name + ': GUI listener', prefix + target + ['python3', '-c', pod_check])
            services = ['mariadb', 'apache2', 'zabbix-server', 'zabbix-agent'] if name == MACHINES[0] else ['zabbix-agent']
            for service in services:
                check(name + ': ' + service, prefix + target + ['service', service, 'status'])
        if args.probe_routing:
            counter = "rows=open('/proc/net/snmp').read().splitlines(); pairs=[r.split()[1:] for r in rows if r.startswith('Ip:')]; print(dict(zip(pairs[0],pairs[1]))['ForwDatagrams'])"
            server = prefix + ['exec', 'deployment/debian-desktop', '--', 'python3', '-c', counter]
            for source in range(1, 4):
                for destination in range(1, 4):
                    if source == destination:
                        continue
                    address = f'192.168.{destination + 1}.1'
                    probe = ("import socket,sys; s=socket.socket(); s.settimeout(3)\n"
                             "try:\n s.connect(('" + address + "',9)); print('response')\n"
                             "except ConnectionRefusedError:\n print('response: TCP RST')\n"
                             "except Exception as e:\n print(type(e).__name__); sys.exit(1)\n"
                             "finally:\n s.close()")
                    before = execute(server)
                    response = check(f'client{source} -> client{destination}', prefix + [
                        'exec', f'deployment/debian-client-{source}', '--', 'python3', '-c', probe])
                    after = execute(server)
                    try:
                        delta = int(after['stdout']) - int(before['stdout'])
                    except ValueError:
                        delta = None
                    report['routing'].append({'source': source, 'destination': destination,
                                              'response': response['exit_code'] == 0,
                                              'forwarding_delta': delta,
                                              'limitation': 'Aggregate counter: corroborate packet path independently'})
    report['status'] = 'checks-completed' if all(c['exit_code'] == 0 for c in report['checks']) else 'incomplete-or-failed'
    report['limitations'] = 'No recovery drill, Zabbix metrics/alert test or proof of packet path. Successful commands are observations, not full application acceptance.'
    if args.output:
        # Exclusive creation prevents overwriting an earlier evidence file.
        with args.output.open('x', encoding='utf-8') as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print('Saved locally; review and sanitize before publishing: ' + str(args.output))
    return 0 if report['status'] == 'checks-completed' else 1


if __name__ == '__main__':
    sys.exit(main())
