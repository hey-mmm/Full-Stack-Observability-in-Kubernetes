# 项目实施计划

本文件是 `outputs/PROJECT-BASELINE.md` 的工程化摘要，不替代基线。基线确认日期为 2026-11-11，所有状态描述均不代表已经部署或验收。

## 1. 范围摘要

在 VMware Workstation + Ubuntu 22.04.5 的两台 VM（1 master + 1 worker）上，以 Ansible 从零构建 Kubernetes 与可观测性平台，并用 GitHub Actions、GHCR、ArgoCD 完成示例应用的构建、发布和 Git 回滚。

第一版不包含：分布式链路追踪、AI 发布风险门禁、Ingress、证书、NFS。

Ansible 在 master 上执行，不由 Windows 宿主机运行。Shell 只承担前置检查、验收、流量、故障与恢复，不替代 Ansible 的配置管理职责。

## 2. 目标架构

```text
Windows 宿主机
  └─ VMware NAT (vmnet8, 11.0.1.0/24)
      ├─ master 11.0.1.10  (2 vCPU / 4 GB, 控制面，保留 NoSchedule taint)
      │    ├─ kube-apiserver / etcd / controller-manager / scheduler
      │    ├─ Ansible 控制端
      │    └─ Calico node（容忍控制面 taint）
      └─ worker 11.0.1.11  (规划 4 vCPU / 12 GB，实际容量以后续检查为准)
           ├─ kubelet / containerd
           └─ Calico node

后续阶段：
  Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics
  Loki 单体 + Grafana Alloy
  local-path 动态本地 PVC
  GitHub Actions -> GHCR -> ArgoCD -> 示例应用
```

### 关键边界

- master 保留 `node-role.kubernetes.io/control-plane:NoSchedule`，不取消 taint；Calico 通过标准清单的 toleration 在 master 运行。
- 基础组件由 Ansible 管理；ArgoCD 只管理示例应用。
- 初始通过端口转发访问界面，不使用 Ingress 或证书。
- local-path 仅验证 Pod 重建后的数据保留，不提供磁盘损坏保护或跨节点迁移。

## 3. 版本决策与来源

核实日期：2026-11-11。以下版本均在编写代码时通过上游官方接口/文档核对，未使用 `latest`。

| 项目 | 固定值 | 依据与结论 |
| --- | --- | --- |
| Kubernetes | `1.37.2`，apt 包 `1.37.2-1.1` | `stable.txt` 为 `v1.37.2`；Kubernetes Releases 页面说明维护最近三个 minor：1.35、1.36、1.37；`pkgs.k8s.io` 的 v1.37 `Packages` 含 amd64 `1.37.2-1.1` |
| Calico | `v3.33.0` | Calico 3.33 官方 requirements 明确“tested against” Kubernetes 1.35、1.36、1.37；官方 manifest sha256 `2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5` |
| containerd | `2.3.6-1~ubuntu.22.04~jammy` | Docker 官方 Ubuntu jammy `Packages` 中存在该固定包；使用 config v3、CRI v1 与 systemd cgroup。未宣称 Kubernetes/Calico 对 containerd 2.3.6 存在逐版本官方测试矩阵 |
| pause 镜像 | `registry.k8s.io/pause:3.10.2` | kubeadm v1.37.2 `PauseVersion` 为 `3.10.2` |
| Ansible Core | `2.21.6` | 官方 release/maintenance 页面显示 Ansible 14.x 依赖 2.21 为当前支持线；2.22 对应的 Ansible 15 仍在开发中。PyPI 要求 Python `>=3.12` |
| Python（控制端） | `3.12.9` | 由 uv 独立安装，不替换系统 Python 3.10；固定 patch |
| `kubernetes.core` | `6.6.0` | Galaxy 元数据 `requires_ansible >=2.16.0` |
| `community.general` | `14.0.1` | Galaxy 元数据 `requires_ansible >=2.19.0` |
| `ansible.posix` | `2.2.2` | Galaxy 元数据 `requires_ansible >=2.16.0` |

主要来源：

- <https://kubernetes.io/releases/>
- <https://dl.k8s.io/release/stable.txt>
- <https://pkgs.k8s.io/core:/stable:/v1.37/deb/Packages>
- <https://docs.tigera.io/calico/3.33/getting-started/kubernetes/requirements>
- <https://github.com/projectcalico/calico/releases/tag/v3.33.0>
- <https://download.docker.com/linux/ubuntu/dists/jammy/stable/binary-amd64/Packages>
- <https://docs.ansible.com/ansible/latest/reference_appendices/release_and_maintenance.html>
- <https://pypi.org/project/ansible-core/2.21.6/>
- <https://galaxy.ansible.com/>

### 为什么选 Kubernetes 1.37.2

1.37 是实施日最新稳定系列；Calico 3.33 官方 requirements 已声明测试 1.35、1.36、1.37。Calico 上游清单中的默认 IPv4 pool 仍是 `192.168.0.0/16`，会与宿主机 VMnet1 冲突，因此仓库使用只读下载源 + 独立渲染目标，把 `CALICO_IPV4POOL_CIDR` 固定为 `10.244.0.0/16`。

### Ansible 控制端 bootstrap

Ubuntu 22.04 默认 Python 3.10 已不足以运行当前受支持的 ansible-core 组合。操作者在 master 上执行（不写入仓库凭据）：

```bash
# 1) 安装 uv（版本由 bootstrap 记录）；不要覆盖系统 python3
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2) 固定独立解释器
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.12.9
uv venv "$HOME/.venvs/ansible" --python 3.12.9

# 3) 固定 Ansible 与 collection；collection 安装到仓库内忽略目录
uv pip install --python "$HOME/.venvs/ansible/bin/python" -r ansible/requirements.txt
$HOME/.venvs/ansible/bin/ansible-galaxy collection install \
  -r ansible/requirements.yml -p ansible/collections

# 4) 后续命令均使用该绝对路径
$HOME/.venvs/ansible/bin/ansible --version
```

不把 `ansible-core 2.17` 作为长期方案：它已 EOL。若未来需要升级到 2.22，必须同时在 uv 中固定 Python 3.13 并复核 collection 支持矩阵，不能只改 pip 版本。

### 网络规划

| 项目 | 值 | 说明 |
| --- | --- | --- |
| Pod CIDR | `10.244.0.0/16` | 与宿主机 `11.0.1.0/24`、VMnet1 `192.168.15.0/24` 不重叠；Calico 清单显式设置 |
| Service CIDR | `10.96.0.0/12` | kubeadm 参数 |
| Cluster DNS | `10.96.0.10` | kubeadm 默认 |
| API endpoint | `11.0.1.10:6443` | 单控制面，无 VIP |
| 容器运行时 socket | `/run/containerd/containerd.sock` | kubeadm/Calico 共用 |

Calico 官方 `calico.yaml` 默认 IPPool 是 `192.168.0.0/16`，会与宿主机 VMnet1 `192.168.15.0/24` 重叠。因此 `roles/calico` 保留带 sha256 校验的只读下载源，复制到独立渲染文件后才把 `CALICO_IPV4POOL_CIDR` 改为 `10.244.0.0/16`，并用断言确认渲染结果；下次运行仍可对上游原文校验 checksum。

## 4. 阶段划分与验收门槛

### 阶段 1：集群底座

交付：

- 系统基线：Ubuntu 22.04 检查、基础包、内核模块、sysctl、swap 关闭、时间同步。
- containerd：固定包、CRI、`SystemdCgroup = true`、暂停镜像固定。
- Kubernetes：固定 apt 源、kubelet/kubeadm/kubectl 固定包与 hold。
- 控制面：`admin.conf` 存在时只做健康检查，不重新 init；部分初始化则明确失败。
- worker：已有 enrollment 时校验 API server、目标集群 Node 对象和 InternalIP；只有缺失时才生成一次性 join 命令，敏感输出 `no_log`。
- Calico：只读下载源 + sha256，独立渲染 Pod CIDR，先 apply、后等待，master taint 保留。
- 验收：两节点 Ready、控制面静态 Pod、CoreDNS、kube-proxy、Calico、DNS、跨节点 Pod 网络。
- 幂等：第二次执行不重建集群，不无条件创建新 token；上游 Calico 文件不被修改，不重复产生变更。
- 执行顺序：系统/运行时 → 控制面 init → Calico apply → worker join → 统一 rollout 验收，避免 master taint 下等待 Calico 控制器而无可调度节点。

验收命令：`scripts/acceptance/cluster.sh`。脚本只检查和创建临时验收命名空间，失败时清理该命名空间；不执行 `kubeadm reset`。

### 阶段 2：示例服务

`/healthz`、`/readyz`、`/metrics`、`/version`；可配置慢请求和错误；JSON 日志包含时间、路径、状态码、耗时、请求标识；指标包含请求数、状态码、耗时。持续流量脚本与接口验收。

### 阶段 3：指标与告警

Prometheus、node-exporter、kube-state-metrics、Grafana、Alertmanager；保留 7 天并设置容量上限；异常和恢复都需真实告警证据；SLO 7 天，99.9% 仅为练习目标。

### 阶段 4：日志与持久化

Loki 单体 + Alloy；保留 3 天并实际启用清理；local-path；验证 Prometheus/Loki Pod 重建后仍能查询重建前数据。

### 阶段 5：稳定性

大量 500、慢请求、启动失败、监控/日志 Pod 重建；记录故障、告警、根因、恢复四个实际时间点；恢复脚本必须限定演练应用。

### 阶段 6：CI/CD 与 GitOps

GitHub Actions 构建并推送 GHCR；ArgoCD 从 Git 发布新版本；通过恢复 Git 配置回退；记录真实发布与回滚证据。

## 5. 幂等与安全设计

1. **控制面保护**：仅当 `/etc/kubernetes/admin.conf` 不存在且 `/etc/kubernetes/manifests/kube-apiserver.yaml` 也不存在时才 init。`admin.conf` 已存在时，`/readyz`、节点读取和 server 版本必须成功匹配；不健康或旧版本则失败并停止，不自动重建。
2. **join 保护**：worker 上 `/etc/kubernetes/kubelet.conf` 已存在时，校验 kubeconfig 的 API server、目标集群 Node 对象和 InternalIP；仅在缺失时由 master 生成 join 命令。join 命令和 init 输出均 `no_log`。
3. **包版本固定**：apt 显式版本安装并使用 `dpkg_selections` hold；升级旧 held 包时显式 `allow_change_held_packages: true`。
4. **Calico 校验**：只读下载源 + 固定 sha256；CIDR 只修改独立渲染文件，应用前断言 `10.244.0.0/16` 已生效。
5. **不删除 taint**：不执行 `kubectl taint nodes --all ...-`。
6. **无凭据入库**：inventory 无密码；`.gitignore` 排除私钥、kubeconfig、Vault、`.env`、真实凭据。
7. **不自动 reset**：验收失败时输出证据，不自动清除控制面或节点状态。

## 6. 已知风险与待验证项

- master 为 2 vCPU / 4 GiB / 50 GB，worker 为 4 vCPU / 12 GiB / 100 GB；完整平台已部署；最终资源快照见 `evidence/final-runtime.txt`，仍需持续观察真实负载。
- Calico 3.33.0 对 Kubernetes 1.37 的兼容性来自官方 requirements；containerd 2.3.6 没有逐版本官方兼容矩阵，已由阶段 1 的 33/33 实跑验收确认本实验环境可用。
- `common` 会把主机名显式设为 inventory 名（master/worker），并同步 `/etc/hosts` 的 `127.0.1.1`。若发现 `/etc/kubernetes/kubelet.conf` 且主机名不一致，会 fail 而不是静默改名已入群节点。
- 旧 1.28 集群由操作者在 playbook 外清理；playbook 发现 `admin.conf` 时只校验健康和版本，发现 1.28 会 fail，绝不会自动 reset/re-init。
- 若 Calico/Kubernetes 上游更新而 checksum 不同，`get_url` 会失败而不是使用未核实内容。
- 端口转发、GHCR 发布、集群镜像运行及本地告警接收端已验证；结果见 README 和 evidence。
