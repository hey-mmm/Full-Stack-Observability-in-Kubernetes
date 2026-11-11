# Recreates only the fixed Prometheus and Loki Pods, keeping their PVCs.
# Explicit --run is required; never deletes PVCs or other namespaces.
import argparse
parser = argparse.ArgumentParser(description="Rebuild Prometheus/Loki Pods and verify old data on the same PVC")
parser.add_argument('--run', action='store_true', help='Perform the two Pod rebuilds')
args = parser.parse_args()
if not args.run:
    parser.error('pass --run to perform this drill; review the documented scope first')
import datetime, json, subprocess, time, urllib.parse, urllib.request
import urllib.error
from pathlib import Path

def k(*args):
    return subprocess.check_output(['kubectl','--request-timeout=20s',*args],text=True)
def get(url, **query):
    if query:
        url += '?' + urllib.parse.urlencode(query)
    try:
        return json.load(urllib.request.urlopen(url,timeout=15))
    except urllib.error.HTTPError as error:
        print(error.read().decode(),flush=True)
        raise
def svc(ns, name, port):
    return 'http://' + k('-n',ns,'get','svc',name,'-o','jsonpath={.spec.clusterIP}') + ':' + str(port)
prom = svc('monitoring','monitoring-kube-prometheus-prometheus',9090)
loki = svc('logging','loki',3100)
demo = svc('demo','demo',8080)
marker = 'persistence-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
request = urllib.request.Request(demo+'/work',headers={'X-Request-ID':marker})
with urllib.request.urlopen(request,timeout=10) as response:
    assert response.status == 200
query = '{namespace="demo"} |= "' + marker + '"'
for attempt in range(30):
    logs = get(loki+'/loki/api/v1/query_range',query=query,limit=10)
    if logs['data']['result']:
        break
    time.sleep(3)
assert logs['data']['result'], 'marker not ingested'
timestamp, line = next((v for stream in logs['data']['result'] for v in stream['values'] if marker in v[1]))
while time.time_ns() <= int(timestamp):
    time.sleep(1)
end = str(time.time_ns())
metric = 'demo_http_requests_total{namespace="demo",route="/work",status="200"}'
for attempt in range(20):
    before = get(prom+'/api/v1/query',query=metric)
    if before['data']['result']:
        break
    time.sleep(3)
assert before['data']['result']
sample = before['data']['result'][0]
at = sample['value'][0]
selector = 'demo_http_requests_total{' + ','.join(key+'='+json.dumps(value) for key,value in sorted(sample['metric'].items()) if key!='__name__') + '}'
output = {'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'marker':marker,'log_timestamp_ns':timestamp,'fixed_query_end_ns':end,
          'prom_query_time':at,'prom_selector':selector,'prom_value_before':sample['value'][1]}
Path('/tmp/persistence-before.json').write_text(json.dumps(output,indent=2))
for ns,pod,pvc_prefix in [('monitoring','prometheus-monitoring-kube-prometheus-prometheus-0','prometheus-'),('logging','loki-0','storage-loki')]:
    old = json.loads(k('-n',ns,'get','pod',pod,'-o','json'))
    pvcs = [v['persistentVolumeClaim']['claimName'] for v in old['spec']['volumes'] if 'persistentVolumeClaim' in v]
    assert pvcs
    k('-n',ns,'delete','pod',pod,'--wait=false')
    for attempt in range(120):
        try:
            current=json.loads(k('-n',ns,'get','pod',pod,'-o','json'))
            ready=any(c['type']=='Ready' and c['status']=='True' for c in current['status'].get('conditions',[]))
            if current['metadata']['uid']!=old['metadata']['uid'] and ready:
                break
        except subprocess.CalledProcessError:
            pass
        time.sleep(2)
    assert ready and current['metadata']['uid']!=old['metadata']['uid'], pod
    after_pvcs=[v['persistentVolumeClaim']['claimName'] for v in current['spec']['volumes'] if 'persistentVolumeClaim' in v]
    assert pvcs==after_pvcs
    output[pod]={'old_uid':old['metadata']['uid'],'new_uid':current['metadata']['uid'],'same_pvcs':pvcs,'ready':True}
after=get(prom+'/api/v1/query',query=selector,time=at)
assert after['data']['result'][0]['value'][1]==sample['value'][1], after
logs_after=get(loki+'/loki/api/v1/query_range',query=query,start=str(int(timestamp)-1000000000),end=end,limit=10)
assert any(v[0]==timestamp and v[1]==line for s in logs_after['data']['result'] for v in s['values']), logs_after
output.update(prom_value_after=after['data']['result'][0]['value'][1],old_log_exact_match=True,
              completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),result='PASS')
Path('/tmp/persistence-acceptance.json').write_text(json.dumps(output,indent=2))
print(json.dumps(output,indent=2))
