#!/usr/bin/env bash
# Stage 1 preflight. Read-only: does not install packages, change sysctl or join a cluster.
set -uo pipefail

ROLE="control-plane"
PEER=""
EXPECTED_IP=""
K8S_VERSION="1.37.2"
ANSIBLE_VENV="${ANSIBLE_VENV:-$HOME/.venvs/ansible}"
MIN_MEM_MB=3500
MIN_ROOT_GIB=20
FAILURES=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: preflight.sh [--role control-plane|worker] [--peer IP] [--expected-ip IP]

Examples:
  ./scripts/preflight.sh --role control-plane --expected-ip 11.0.1.10
  ./scripts/preflight.sh --role worker --peer 11.0.1.10 --expected-ip 11.0.1.11
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --peer) PEER="${2:-}"; shift 2 ;;
    --expected-ip) EXPECTED_IP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$ROLE" != "control-plane" && "$ROLE" != "worker" ]]; then
  echo "--role must be control-plane or worker" >&2
  exit 2
fi

ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

echo "== Stage 1 preflight: role=${ROLE} host=$(hostname -s 2>/dev/null || hostname) =="

if [[ "${EUID}" -ne 0 ]]; then
  if sudo -n true >/dev/null 2>&1; then
    ok "passwordless sudo is available for $(id -un)"
  else
    bad "passwordless sudo is not available; Ansible become will fail"
  fi
else
  ok "running as root"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]]; then
    ok "Ubuntu 22.04 detected (${PRETTY_NAME:-unknown})"
  else
    bad "expected Ubuntu 22.04, got ${ID:-unknown} ${VERSION_ID:-unknown}"
  fi
else
  bad "/etc/os-release is not readable"
fi

if [[ "$(uname -m)" == "x86_64" ]]; then
  ok "architecture x86_64"
else
  bad "architecture $(uname -m) is not x86_64"
fi

if have nproc; then
  CPUS="$(nproc)"
  if (( CPUS >= 2 )); then
    ok "CPU count ${CPUS}"
  else
    bad "CPU count ${CPUS} is below the stage 1 minimum of 2"
  fi
else
  bad "nproc is unavailable"
fi

if [[ -r /proc/meminfo ]]; then
  MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( MEM_MB >= MIN_MEM_MB )); then
    ok "memory ${MEM_MB} MiB"
  else
    bad "memory ${MEM_MB} MiB is below ${MIN_MEM_MB} MiB"
  fi
  if [[ "$ROLE" == "worker" ]] && (( MEM_MB < 8000 )); then
    warn "worker has ${MEM_MB} MiB; the full observability stack may not fit"
  fi
else
  bad "/proc/meminfo is not readable"
fi

if have df; then
  ROOT_GIB="$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')"
  if (( ROOT_GIB >= MIN_ROOT_GIB )); then
    ok "root filesystem free ${ROOT_GIB} GiB"
  else
    bad "root filesystem free ${ROOT_GIB} GiB is below ${MIN_ROOT_GIB} GiB"
  fi
  if [[ "$ROLE" == "control-plane" ]] && (( ROOT_GIB < 40 )); then
    warn "control-plane free space ${ROOT_GIB} GiB is tight for later phases"
  fi
else
  bad "df is unavailable"
fi

if have swapon; then
  SWAP_LINES="$(swapon --show=NAME --noheadings 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${SWAP_LINES}" == "0" ]]; then
    ok "swap is disabled"
  else
    bad "active swap entries: ${SWAP_LINES}; the playbook will disable them"
  fi
else
  bad "swapon is unavailable"
fi

for module in overlay br_netfilter; do
  if grep -q "^${module} " /proc/modules 2>/dev/null; then
    ok "kernel module ${module} is loaded"
  elif have modprobe && modprobe -n "$module" >/dev/null 2>&1; then
    warn "kernel module ${module} is not loaded yet but is available"
  else
    bad "kernel module ${module} is unavailable"
  fi
done

check_sysctl() {
  local key="$1" expected="$2" actual
  actual="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    ok "sysctl ${key}=${actual}"
  else
    warn "sysctl ${key}=${actual:-unreadable}, expected ${expected} after playbook run"
  fi
}
if have sysctl; then
  check_sysctl net.ipv4.ip_forward 1
  check_sysctl net.bridge.bridge-nf-call-iptables 1
  check_sysctl net.bridge.bridge-nf-call-ip6tables 1
fi

if have timedatectl; then
  NTP_STATE="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$NTP_STATE" == "yes" ]]; then
    ok "time is NTP-synchronized"
  else
    warn "time is not currently NTP-synchronized (NTPSynchronized=${NTP_STATE:-unknown})"
  fi
else
  warn "timedatectl is unavailable; inspect time synchronization manually"
fi

for host in registry.k8s.io pkgs.k8s.io download.docker.com raw.githubusercontent.com; do
  if have getent && timeout 5 getent ahostsv4 "$host" >/dev/null 2>&1; then
    ok "DNS resolves ${host}"
  else
    bad "DNS resolution failed for ${host} (timeout 5s)"
  fi
done

if [[ -n "$EXPECTED_IP" ]]; then
  if ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$EXPECTED_IP"; then
    ok "expected IPv4 ${EXPECTED_IP} is configured"
  else
    bad "expected IPv4 ${EXPECTED_IP} is not configured on this host"
  fi
fi

if [[ -n "$PEER" ]]; then
  if have ping && timeout 5 ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; then
    ok "peer ${PEER} responds to ping"
  else
    bad "peer ${PEER} does not respond to ping (timeout 5s)"
  fi
  if timeout 5 bash -c "</dev/tcp/${PEER}/22" >/dev/null 2>&1; then
    ok "peer ${PEER} has TCP/22 reachable"
  else
    bad "peer ${PEER} TCP/22 is not reachable (timeout 5s)"
  fi
fi

if have ss; then
  check_port() {
    local port="$1" label="$2"
    if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      warn "${label} TCP/${port} is already listening; if this is a legacy cluster, clean it before stage 1"
    else
      ok "${label} TCP/${port} is free"
    fi
  }
  if [[ "$ROLE" == "control-plane" ]]; then
    check_port 6443 "API server"
  else
    check_port 10250 "kubelet"
  fi
  if ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]4789$'; then
    warn "UDP/4789 is already listening; Calico or a legacy CNI may be active"
  fi
else
  bad "ss is unavailable"
fi

if have kubeadm; then
  INSTALLED_K8S="$(timeout 15 kubeadm version -o short 2>/dev/null | tr -d '[:space:]')"
  if [[ "$INSTALLED_K8S" == "v${K8S_VERSION}" ]]; then
    ok "kubeadm already matches v${K8S_VERSION}"
  else
    warn "kubeadm=${INSTALLED_K8S:-unknown}, target v${K8S_VERSION}. A legacy 1.28 cluster must be cleaned deliberately; the playbook will not re-init over an existing admin.conf."
  fi
else
  ok "kubeadm is not installed yet"
fi

if [[ -f /etc/kubernetes/admin.conf ]]; then
  warn "/etc/kubernetes/admin.conf exists; role control_plane will validate it and refuse a wrong-version or unhealthy cluster"
fi
if [[ "$ROLE" == "worker" && -f /etc/kubernetes/kubelet.conf ]]; then
  warn "/etc/kubernetes/kubelet.conf exists; join role will verify its API server and Node ownership instead of assuming enrollment"
fi

if [[ "$ROLE" == "control-plane" ]]; then
  if [[ -x "$ANSIBLE_VENV/bin/ansible" ]]; then
    ok "Ansible bootstrap exists at $ANSIBLE_VENV/bin/ansible"
  elif have ansible; then
    warn "ansible is on PATH ($(command -v ansible)); verify it was installed with uv-managed Python 3.12.9 and ansible-core 2.21.6"
  else
    warn "Ansible is not installed yet; run the documented bootstrap before the playbook"
  fi

  if [[ -x "$ANSIBLE_VENV/bin/python" ]]; then
    PY_VERSION="$("$ANSIBLE_VENV/bin/python" --version 2>&1)"
    if [[ "$PY_VERSION" == "Python 3.12.9" ]]; then
      ok "Ansible Python is ${PY_VERSION}"
    else
      warn "Ansible Python is ${PY_VERSION}, expected Python 3.12.9"
    fi
  fi
fi

echo
echo "== Summary: failures=${FAILURES}, warnings=${WARNINGS} =="
if (( FAILURES > 0 )); then
  echo "Preflight failed; resolve [FAIL] items before running Ansible."
  exit 1
fi
echo "Preflight passed; review warnings before running Ansible."
