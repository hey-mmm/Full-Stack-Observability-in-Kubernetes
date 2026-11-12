#!/usr/bin/env python3
"""Read-only proof that Argo's Git revision and the served image agree."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import urllib.error

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image-sha', required=True)
parser.add_argument('--git-revision', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()

def k(*arguments):
    return json.loads(subprocess.check_output(
        ['kubectl', '--request-timeout=15s', *arguments, '-o', 'json'], text=True))

for attempt in range(90):
    app = k('-n', 'argocd', 'get', 'application', 'demo')
    status = app.get('status', {})
    if (status.get('sync', {}).get('status') == 'Synced'
        and status.get('sync', {}).get('revision') == args.git_revision
        and status.get('health', {}).get('status') == 'Healthy'):
        break
    time.sleep(2)
else:
    raise SystemExit('Application did not reach expected Git revision: ' + json.dumps(status))

assert app['spec']['project'] == 'demo'
assert app['spec']['source']['repoURL'] == 'https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes.git'
assert app['spec']['destination']['namespace'] == 'demo'
assert app['spec']['syncPolicy']['automated']['selfHeal'] is True
assert app['spec']['syncPolicy']['automated']['prune'] is True
project = k('-n', 'argocd', 'get', 'appproject', 'demo')
assert not project['spec'].get('clusterResourceWhitelist')
assert project['spec']['sourceRepos'] == [app['spec']['source']['repoURL']]
assert project['spec']['destinations'] == [
    {'namespace': 'demo', 'server': 'https://kubernetes.default.svc'}]
assert {(r['group'], r['kind']) for r in project['spec']['namespaceResourceWhitelist']} == {
    ('apps', 'Deployment'), ('', 'Service'), ('monitoring.coreos.com', 'ServiceMonitor')}
deployment = k('-n', 'demo', 'get', 'deployment', 'demo')
image = deployment['spec']['template']['spec']['containers'][0]['image']
assert image == 'ghcr.io/hey-mmm/observability-demo:sha-' + args.image_sha, image
service = k('-n', 'demo', 'get', 'service', 'demo')
assert service['spec']['type'] == 'ClusterIP'
endpoint = 'http://' + service['spec']['clusterIP'] + ':8080'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
# Argo status and Service endpoints may converge at different instants during a
# rolling update. Require the expected version and all HTTP checks in one pass.
http_deadline = time.monotonic() + 90
while True:
    try:
        with opener.open(endpoint + '/version', timeout=5) as response:
            version = json.load(response)
        assert version['git_sha'] == args.image_sha, version
        for route in ['/healthz', '/readyz', '/work']:
            with opener.open(endpoint + route, timeout=5) as response:
                assert response.status == 200
        break
    except (urllib.error.URLError, TimeoutError, AssertionError) as error:
        if time.monotonic() >= http_deadline:
            raise SystemExit('Service did not converge to expected version: ' + str(error))
        time.sleep(2)
pods = k('-n', 'argocd', 'get', 'pods')['items']
core = [p for p in pods if p['metadata']['name'].startswith(
    ('argocd-application-controller-', 'argocd-repo-server-', 'argocd-server-', 'argocd-redis-'))
    and 'secret-init' not in p['metadata']['name']]
assert len(core) == 4
assert all(any(c['type'] == 'Ready' and c['status'] == 'True'
               for c in p['status']['conditions']) for p in core)
result = {
    'observed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'git_revision': status['sync']['revision'],
    'sync': status['sync']['status'], 'health': status['health']['status'],
    'auto_sync': app['spec']['syncPolicy']['automated'],
    'image': image, 'version': version,
    'project_cluster_writes': False, 'core_pods_ready': len(core),
    'health_readiness_work_http': 200, 'result': 'PASS',
}
Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
