#!/usr/bin/env bash
# Stage 1 cluster acceptance. Creates a temporary namespace and removes it on exit.
# Never removes the control-plane taint and never runs kubeadm reset.
set -uo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export KUBECONFIG
NS="observability-acceptance-$$"
TEST_IMAGE="${NETCHECK_IMAGE:-busybox:1.36.1}"
EXPECTED_NODES="${EXPECTED_NODES:-master worker}"
EXPECTED_MASTER_IP="${EXPECTED_MASTER_IP:-11.0.1.10}"
EXPECTED_WORKER_IP="${EXPECTED_WORKER_IP:-11.0.1.11}"
EXPECTED_DNS_IP="${EXPECTED_DNS_IP:-10.96.0.10}"
EXPECTED_KUBE_SVC_IP="${EXPECTED_KUBE_SVC_IP:-10.96.0.1}"
FAILS=0
PASSES=0

pass() { printf '[PASS] %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

k() { timeout 30 kubectl --request-timeout=15s "$@"; }

cleanup() {
  timeout 20 kubectl --request-timeout=10s delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== Stage 1 cluster acceptance =="
echo "kubeconfig=${KUBECONFIG} namespace=${NS} test_image=${TEST_IMAGE}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl is not on PATH" >&2
  exit 1
fi
if [[ ! -r "$KUBECONFIG" ]]; then
  echo "[FAIL] kubeconfig is not readable: $KUBECONFIG" >&2
  exit 1
fi

if timeout 20 kubectl --request-timeout=15s get --raw=/readyz >/dev/null 2>&1; then
  pass "API /readyz"
else
  fail "API /readyz is not healthy"
  echo "Cannot continue without a healthy API server." >&2
  exit 1
fi

mapfile -t NODES < <(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [[ "${#NODES[@]}" -eq 2 ]]; then
  pass "node count is 2"
else
  fail "expected 2 nodes, got ${#NODES[@]}"
fi

for expected in $EXPECTED_NODES; do
  found=0
  for node in "${NODES[@]:-}"; do
    [[ "$node" == "$expected" ]] && found=1
  done
  if [[ "$found" -eq 1 ]]; then
    pass "expected node ${expected} exists"
  else
    fail "expected node ${expected} is absent"
  fi
done

for node in "${NODES[@]:-}"; do
  ready="$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$ready" == "True" ]]; then
    pass "node ${node} is Ready"
  else
    fail "node ${node} is not Ready (Ready=${ready:-unknown})"
  fi
  runtime="$(k get node "$node" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)"
  if [[ "$runtime" == containerd://* ]]; then
    pass "node ${node} runtime=${runtime}"
  else
    fail "node ${node} runtime=${runtime:-unknown}, expected containerd"
  fi
done

check_internal_ip() {
  local node="$1" expected_ip="$2" actual
  actual="$(k get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ "$actual" == "$expected_ip" ]]; then
    pass "node ${node} InternalIP=${actual}"
  else
    fail "node ${node} InternalIP=${actual:-unknown}, expected ${expected_ip}"
  fi
}
check_internal_ip master "$EXPECTED_MASTER_IP"
check_internal_ip worker "$EXPECTED_WORKER_IP"

for component in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  if timeout 150 kubectl --request-timeout=15s -n kube-system wait \
      --for=condition=Ready pod -l "component=${component}" --timeout=120s >/dev/null 2>&1; then
    pass "control-plane pod ${component} is Ready"
  else
    fail "control-plane pod ${component} is not Ready"
  fi
done

if timeout 200 kubectl --request-timeout=15s -n kube-system rollout status \
    daemonset/kube-proxy --timeout=180s >/dev/null 2>&1; then
  pass "kube-proxy DaemonSet is ready"
else
  fail "kube-proxy DaemonSet is not ready"
fi

if timeout 200 kubectl --request-timeout=15s -n kube-system rollout status \
    daemonset/calico-node --timeout=180s >/dev/null 2>&1; then
  pass "calico-node DaemonSet is ready"
else
  fail "calico-node DaemonSet is not ready"
fi

if timeout 200 kubectl --request-timeout=15s -n kube-system rollout status \
    deployment/calico-kube-controllers --timeout=180s >/dev/null 2>&1; then
  pass "calico-kube-controllers is ready"
else
  fail "calico-kube-controllers is not ready"
fi

if timeout 200 kubectl --request-timeout=15s -n kube-system rollout status \
    deployment/coredns --timeout=180s >/dev/null 2>&1; then
  pass "CoreDNS is ready"
else
  fail "CoreDNS is not ready"
fi

kube_svc_ip="$(k -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ "$kube_svc_ip" == "$EXPECTED_KUBE_SVC_IP" ]]; then
  pass "kubernetes Service ClusterIP=${kube_svc_ip}"
else
  fail "kubernetes Service ClusterIP=${kube_svc_ip:-unknown}, expected ${EXPECTED_KUBE_SVC_IP}"
fi

dns_svc_ip="$(k -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ "$dns_svc_ip" == "$EXPECTED_DNS_IP" ]]; then
  pass "kube-dns ClusterIP=${dns_svc_ip}"
else
  fail "kube-dns ClusterIP=${dns_svc_ip:-unknown}, expected ${EXPECTED_DNS_IP}"
fi

TAINTS="$(k get node master -o jsonpath='{range .spec.taints[*]}{.key}{"\n"}{end}' 2>/dev/null || true)"
if grep -qx 'node-role.kubernetes.io/control-plane' <<<"$TAINTS"; then
  pass "master control-plane taint is preserved"
else
  fail "master control-plane taint is missing"
fi

CALICO_TOLERATIONS="$(k -n kube-system get ds calico-node -o jsonpath='{range .spec.template.spec.tolerations[*]}{.operator}{"\n"}{end}' 2>/dev/null || true)"
if grep -qx 'Exists' <<<"$CALICO_TOLERATIONS"; then
  pass "calico-node tolerates the control-plane taint"
else
  fail "calico-node does not have an Exists toleration"
fi

KUBEADM_POD_SUBNET="$(k -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep -E 'podSubnet:' || true)"
if grep -q '10.244.0.0/16' <<<"$KUBEADM_POD_SUBNET"; then
  pass "kubeadm podSubnet is 10.244.0.0/16"
else
  fail "kubeadm podSubnet is not 10.244.0.0/16 (${KUBEADM_POD_SUBNET:-not found})"
fi

CALICO_POOL_CIDR="$(k get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr}' 2>/dev/null || true)"
if [[ "$CALICO_POOL_CIDR" == "10.244.0.0/16" ]]; then
  pass "Calico default IPv4 IPPool=${CALICO_POOL_CIDR}"
else
  fail "Calico default IPv4 IPPool=${CALICO_POOL_CIDR:-not found}, expected 10.244.0.0/16"
fi

if k create namespace "$NS" >/dev/null 2>&1; then
  pass "created temporary acceptance namespace ${NS}"
else
  fail "could not create temporary namespace ${NS}"
  echo "Skipping Pod network checks because the namespace could not be created." >&2
  printf '\n== Summary: passes=%d, failures=%d ==\n' "$PASSES" "$FAILS"
  exit 1
fi

cat <<EOF | timeout 30 kubectl --request-timeout=15s apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: netcheck-master
  namespace: ${NS}
spec:
  nodeName: master
  tolerations:
    - operator: Exists
  containers:
    - name: netcheck
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: netcheck-worker
  namespace: ${NS}
spec:
  nodeName: worker
  tolerations:
    - operator: Exists
  containers:
    - name: netcheck
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
EOF

if [[ $? -eq 0 ]]; then
  pass "submitted temporary cross-node test Pods"
else
  fail "could not submit temporary cross-node test Pods"
fi

if timeout 240 kubectl --request-timeout=15s -n "$NS" wait \
    --for=condition=Ready pod/netcheck-master pod/netcheck-worker --timeout=180s >/dev/null 2>&1; then
  pass "temporary test Pods are Ready"
else
  fail "temporary test Pods did not become Ready"
  k -n "$NS" get pods -o wide || true
fi

MASTER_POD_IP="$(k -n "$NS" get pod netcheck-master -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
WORKER_POD_IP="$(k -n "$NS" get pod netcheck-worker -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
if [[ -n "$MASTER_POD_IP" && -n "$WORKER_POD_IP" && "$MASTER_POD_IP" != "$WORKER_POD_IP" ]]; then
  pass "Pod IPs allocated: master=${MASTER_POD_IP}, worker=${WORKER_POD_IP}"
else
  fail "Pod IPs are missing or identical: master=${MASTER_POD_IP:-none}, worker=${WORKER_POD_IP:-none}"
fi

if timeout 30 kubectl --request-timeout=15s -n "$NS" exec netcheck-master -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
  pass "cluster DNS resolves kubernetes.default.svc.cluster.local"
else
  fail "cluster DNS lookup failed"
fi

if [[ -n "$WORKER_POD_IP" ]] && timeout 30 kubectl --request-timeout=15s -n "$NS" exec \
    netcheck-master -- ping -c 2 -W 2 "$WORKER_POD_IP" >/dev/null 2>&1; then
  pass "cross-node Pod network master -> worker"
else
  fail "cross-node Pod network master -> worker failed"
fi

if [[ -n "$MASTER_POD_IP" ]] && timeout 30 kubectl --request-timeout=15s -n "$NS" exec \
    netcheck-worker -- ping -c 2 -W 2 "$MASTER_POD_IP" >/dev/null 2>&1; then
  pass "cross-node Pod network worker -> master"
else
  fail "cross-node Pod network worker -> master failed"
fi

printf '\n== Summary: passes=%d, failures=%d ==\n' "$PASSES" "$FAILS"
if (( FAILS > 0 )); then
  echo "Stage 1 acceptance FAILED." >&2
  exit 1
fi
echo "Stage 1 acceptance PASSED."
