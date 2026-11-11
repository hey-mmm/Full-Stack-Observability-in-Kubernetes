# 基于 Ansible 的 Kubernetes 可观测性与 GitOps 平台

本项目在 VMware Workstation 中的 Ubuntu 22.04.5 虚拟机上，以 1 master + 1 worker 构建可重复、可验收的 Kubernetes 可观测性实验平台。项目强调真实测量、可解释的自动化、故障演练与恢复证据，不以“脚本执行成功”代替验收。

> **当前状态：阶段 1 代码已编写，尚未在目标 VM 上执行，未部署、未验收、未 push。**
>
> 仓库中不存在“已部署”或“已通过”的结论。所有阶段验收结果必须在目标环境实际执行后另行记录。

## 目标

1. 用 Ansible 管理 Ubuntu 系统基线、containerd、Kubernetes、Calico 和后续观测组件。
2. 用 Shell 承担前置检查、集群验收、流量生成、故障注入与恢复检查，不替代 Ansible 配置管理。
3. 部署无数据库的 Python Web 示例服务，采集指标、日志并配置告警。
4. 用 GitHub Actions、GHCR、ArgoCD 管理示例应用的发布与 Git 回滚。
5. 对故障、告警、恢复和发布回滚保留真实时间线与证据。

第一版明确不包含：分布式链路追踪、AI 发布风险门禁、Ingress、证书管理、NFS。

## 六阶段验收状态

| 阶段 | 内容 | 当前状态 |
| --- | --- | --- |
| 1 | 集群底座：两节点 Ready，DNS、网络、服务正常，重复执行不破坏集群 | **代码已编写，未部署、未验收** |
| 2 | 示例服务：接口、健康检查、指标、JSON 日志、版本与持续流量 | 未开始 |
| 3 | 指标与告警：主机/Pod/应用指标可查询，异常与恢复有真实通知证据 | 未开始 |
| 4 | 日志与持久化：两节点日志可查，Prometheus/Loki Pod 重建后数据仍可查 | 未开始 |
| 5 | 稳定性：500、慢请求、启动失败、监控/日志 Pod 重建的故障与恢复 | 未开始 |
| 6 | CI/CD 与 GitOps：Actions 构建发布，ArgoCD 发布并由 Git 恢复回滚 | 未开始 |

阶段必须按顺序验收；提前编写后续阶段代码不代表该阶段已通过。仓库中可能同时存在并行准备的后续阶段草稿，其状态仍以实际阶段验收记录为准。

## 架构边界

- **Ansible（master 上运行）**：系统基线、时间同步、内核参数、swap、containerd、kubeadm、控制面初始化、worker 加入、Calico、后续观测组件和 ArgoCD。
- **Shell**：前置检查、阶段验收、流量、故障与恢复；不负责替代配置管理。
- **Kubernetes**：kubeadm + containerd（systemd cgroup）+ Calico。
- **观测栈（后续阶段）**：Prometheus、node-exporter、kube-state-metrics、Grafana、Alertmanager、Loki 单体、Grafana Alloy、local-path。
- **GitOps（后续阶段）**：仅管理示例应用；基础组件仍由 Ansible 管理。

## 版本基线

| 组件 | 固定版本 | 说明 |
| --- | --- | --- |
| Ubuntu | 22.04.5 | 目标 VM 基线 |
| Kubernetes | `1.37.2` / 包版本 `1.37.2-1.1` | 实施日最新稳定版；Kubernetes 官方维护 1.35–1.37 |
| Calico | `v3.33.0` | 官方 requirements 标注测试 Kubernetes 1.35、1.36、1.37 |
| containerd | `2.3.6-1~ubuntu.22.04~jammy` | Docker 官方 jammy 仓库固定包；config v3，CRI v1，systemd cgroup |
| pause 镜像 | `registry.k8s.io/pause:3.10.2` | kubeadm v1.37.2 的默认 pause 版本 |
| Ansible Core | `2.21.6` | 当前支持线；由 uv 管理的独立 Python `3.12.9` 运行，不依赖系统 Python 3.10 |
| Pod CIDR | `10.244.0.0/16` | 与 Calico 渲染清单中的 IPPool 显式对齐 |
| Service CIDR | `10.96.0.0/12` | 集群 Service 网段 |
| Cluster DNS | `10.96.0.10` | kubeadm 默认服务网段内地址 |

VM 实际容量已由主代理确认：master 2 vCPU / 4 GiB / 50 GB，worker 4 vCPU / 12 GiB / 100 GB。旧 1.28 集群允许直接清理，但清理动作由主代理在 playbook 之外执行；本仓库不会自动 `kubeadm reset`。

Calico `v3.33.0` 官方 `manifests/calico.yaml` 的 sha256 为
`2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5`，已在 `group_vars/all.yml` 与下载任务中固定。

版本来源与选择依据见 [docs/plan.md](docs/plan.md)。所有版本均固定，不使用 `latest`。

## 目录

```text
.
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml          # 固定 collection 版本
│   ├── requirements.txt          # 固定 ansible-core（uv Python 3.12.9）
│   ├── inventory/lab.yml         # myt + 两个 VM 地址，不含密码
│   ├── group_vars/all.yml        # 版本、网络、CIDR、保留期、容量
│   ├── playbooks/site.yml
│   └── roles/
│       ├── common/               # 系统基线、内核、swap、时间
│       ├── containerd/           # 安装与 systemd cgroup
│       ├── kubernetes/           # apt 仓库、kubelet/kubeadm/kubectl
│       ├── control_plane/        # 受保护的 kubeadm init
│       ├── calico/               # 固定清单、CIDR 对齐、部署
│       └── worker_join/          # 幂等 join，敏感输出 no_log
├── scripts/
│   ├── preflight.sh
│   └── acceptance/cluster.sh
└── docs/
    ├── plan.md
    └── stage1-runbook.md
```

## 快速入口

阶段 1 尚不可宣称成功。实际执行步骤见 [docs/stage1-runbook.md](docs/stage1-runbook.md)，总体设计与阶段划分见 [docs/plan.md](docs/plan.md)。

## 安全约定

- 仓库不保存 SSH 私钥、密码、token、kubeconfig、`.env` 或真实凭据。
- `inventory/lab.yml` 只保存地址与用户名；认证由执行环境提供。
- join 命令与 kubeadm init 输出使用 `no_log`，避免 token 进入日志。
- Calico 上游清单保持只读，CIDR 修改写入独立渲染文件；下载使用固定 sha256。
- 不自动删除控制面 taint；master 保留控制面调度限制。
- 不在验收脚本中自动 `kubeadm reset`，避免误毁已有集群。
- 不自动重新初始化 `admin.conf` 已存在的集群；版本或健康状态不符时立即失败。
