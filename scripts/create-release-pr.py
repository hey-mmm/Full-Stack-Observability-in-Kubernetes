#!/usr/bin/env python3
"""Create a release PR after verifying CI and GHCR provenance; never push main."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.parse
import urllib.request

REPO = 'hey-mmm/Full-Stack-Observability-in-Kubernetes'
IMAGE = 'hey-mmm/observability-demo'


def request(url, token=None, body=None, method=None, accept='application/vnd.github+json'):
    headers = {'Accept': accept, 'User-Agent': 'observability-release-pr',
               'X-GitHub-Api-Version': '2022-11-28'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, headers=headers, data=data, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('response exceeds size limit')
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True, help='Successful main build commit, full SHA')
    parser.add_argument('--digest', required=True, help='CI-published sha256 manifest/index digest')
    parser.add_argument('--token-file', type=Path)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{40}', args.commit):
        parser.error('--commit must be 40 lowercase hex characters')
    if not re.fullmatch('sha256:[0-9a-f]{64}', args.digest):
        parser.error('--digest must be sha256:<64 lowercase hex>')
    token = args.token_file.read_text().strip() if args.token_file else os.environ.get('GITHUB_TOKEN')
    if not token:
        parser.error('set GITHUB_TOKEN or supply --token-file')
    api = 'https://api.github.com/repos/' + REPO

    def gh(path, body=None, method=None):
        return json.loads(request(api + path, token, body, method))

    runs = gh('/actions/workflows/ci.yml/runs?head_sha=' + args.commit + '&per_page=100')['workflow_runs']
    successful = [r for r in runs if r['head_sha'] == args.commit and r['head_branch'] == 'main'
                  and r['event'] == 'push' and r['conclusion'] == 'success']
    if not successful:
        raise SystemExit('No successful main push CI for the requested commit')
    run = successful[0]
    jobs = gh('/actions/runs/' + str(run['id']) + '/jobs?per_page=100')['jobs']
    if not any(j['name'] == 'Build and push image' and j['conclusion'] == 'success' for j in jobs):
        raise SystemExit('CI did not complete Build and push image')
    registry_token = json.loads(request('https://ghcr.io/token?service=ghcr.io&scope=' +
                                       urllib.parse.quote('repository:' + IMAGE + ':pull')))['token']
    manifest_accept = ','.join(['application/vnd.oci.image.index.v1+json',
                               'application/vnd.docker.distribution.manifest.list.v2+json',
                               'application/vnd.oci.image.manifest.v1+json',
                               'application/vnd.docker.distribution.manifest.v2+json'])

    def manifest(digest):
        raw = request('https://ghcr.io/v2/' + IMAGE + '/manifests/' + digest,
                      registry_token, accept=manifest_accept)
        if 'sha256:' + hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('GHCR response does not match digest')
        return json.loads(raw)

    image = manifest(args.digest)
    if 'manifests' in image:
        platforms = [m for m in image['manifests'] if m.get('platform', {}).get('os') == 'linux'
                     and m.get('platform', {}).get('architecture') == 'amd64']
        if len(platforms) != 1:
            raise ValueError('Expected one linux/amd64 manifest')
        image = manifest(platforms[0]['digest'])
    config_digest = image['config']['digest']
    config_raw = request('https://ghcr.io/v2/' + IMAGE + '/blobs/' + config_digest, registry_token)
    if 'sha256:' + hashlib.sha256(config_raw).hexdigest() != config_digest:
        raise ValueError('Image config digest mismatch')
    labels = json.loads(config_raw)['config'].get('Labels', {})
    if labels.get('org.opencontainers.image.revision') != args.commit:
        raise ValueError('Image revision label does not match requested build')
    if labels.get('org.opencontainers.image.source') != 'https://github.com/' + REPO:
        raise ValueError('Image source label does not match repository')
    base = gh('/git/ref/heads/main')['object']['sha']
    path = '/contents/gitops/demo/values.yaml'
    original = gh(path + '?ref=' + base)
    text = base64.b64decode(original['content']).decode()
    text, count = re.subn(r'(?m)^  tag:.*$', '  tag: sha-' + args.commit, text)
    if count != 1:
        raise ValueError('Expected exactly one image.tag')
    if re.search(r'(?m)^  digest:', text):
        text = re.sub(r'(?m)^  digest:.*$', '  digest: ' + args.digest, text)
    else:
        text = text.replace('  tag: sha-' + args.commit + '\n',
                            '  tag: sha-' + args.commit + '\n  digest: ' + args.digest + '\n')
    text, count = re.subn(r'(?m)^gitSha:.*$', 'gitSha: ' + args.commit, text)
    if count != 1:
        raise ValueError('Expected exactly one gitSha')
    text = re.sub(r'(?m)^appVersion:.*$', 'appVersion: 0.1.0-' + args.commit, text)
    text = re.sub(r'(?m)^# Verified CI image;.*\n', '', text)
    branch = 'release/' + args.commit[:12] + '-' + args.digest[7:15]
    gh('/git/refs', {'ref': 'refs/heads/' + branch, 'sha': base})
    update = gh(path, {'message': 'Promote verified digest ' + args.digest,
                      'content': base64.b64encode(text.encode()).decode(),
                      'sha': original['sha'], 'branch': branch}, 'PUT')
    pr = gh('/pulls', {'title': 'Release ' + args.commit[:12] + ' by digest', 'head': branch,
                      'base': 'main', 'body': 'Promote CI build ' + args.commit +
                      '\n\nImage: `ghcr.io/' + IMAGE + '@' + args.digest +
                      '`\n\nVerified CI: ' + run['html_url'] +
                      '\n\nCI success, manifest digest, image config revision and source verified. '
                      'Wait for change-guard/release and CI; merge only through the protected PR.'})
    print(json.dumps({'pr': pr['html_url'], 'head_sha': update['commit']['sha'],
                      'base_sha': base, 'image_digest': args.digest}, indent=2))


if __name__ == '__main__':
    main()
