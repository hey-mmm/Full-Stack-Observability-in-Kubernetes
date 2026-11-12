# 基于 Ansible 的 Kubernetes 可观测性与 GitOps 平台

> 项目二发布流程接入见 [发布风险门禁](docs/change-guard.md)。启用保护后的发布和回退均走 PR，使用镜像 digest；下文项目一验收数字是保留的历史证据。

本项目在 VMware Workstation 中的 Ubuntu 22.04.5 虚拟机上，以 1 master + 1 worker 构建可重复、可验收的 Kubernetes 可观测性实验平台。重点不是“脚本能跑”，而是用真实测量、故障时间线和持久化证据证明平台可用、可定位、可恢复。

> **状态（2026-11-12，以 `docs/evidence/` 为准）**
>
> - 集群验收 **33/33 PASS**；全量 `site.yml` 最终复跑 **master 83 个任务 / worker 62 个任务，changed=0 / changed=0**，完整日志见 `docs/evidence/stage1-idempotency.txt`。
> - 示例服务 **8 项单元测试 + 7/7 运行验收 PASS**；Actions 构建与 GHCR 发布成功。
> - local-path **4/4**、指标与告警 **16/16**、日志 **10/10** PASS。
> - HTTP 500、3000 ms 慢请求、启动失败三项演练完成；Prometheus/Loki Pod 重建后的**持久化验证 PASS**。
> - **GitOps 发布和 Git 回退均 PASS**；Application 为 Synced/Healthy，4 个核心 Pod 健康，运行版本与期望镜像一致。
>
> 真实记录位于 [docs/evidence](docs/evidence)。配置已编写、Pod 已启动，都不等于对应验收已通过。

## 项目做什么

1. 用 Ansible 从裸 Ubuntu 建立系统基线、containerd、Kubernetes、Calico，并以幂等方式加入 worker。
2. 部署无数据库的 Python Web 示例服务，暴露 `/healthz`、`/readyz`、`/work`、`/metrics`、`/version`，输出 JSON 日志和 request_id。
3. 用 kube-prometheus-stack 采集节点、Kubernetes 对象、kubelet、API、DNS 与 demo 指标，配置 Prometheus 规则、Alertmanager 和本地 JSON webhook receiver。
4. 用 Alloy 采集两节点 Pod 日志写入 Loki，Grafana 统一展示指标与日志；local-path 为 Prometheus/Loki 等提供 PVC。
5. 用 GitHub Actions + GHCR 构建不可变 `sha-<commit>` 镜像，Argo CD 只管理 demo 应用；基础平台仍由 Ansible/Helm 管理。
6. 用 Shell 做前置检查、验收、流量与故障注入，并保留故障开始、告警、恢复、持久化的原始证据。

第一版不包含分布式链路追踪、Ingress、证书管理、NFS、多 worker 高可用或生产级备份。

## 数据流

```text
用户/压测 ──HTTP──> demo Service ──> demo Pod (/work)
                                      │  /metrics（请求数、延迟直方图）
                                      │  stdout JSON 日志
                                      ▼
             ServiceMonitor ──> Prometheus <── node-exporter / KSM / kubelet / API / DNS
                                      │
                                      ├─ 规则求值 ──> Alertmanager ──webhook──> alert-receiver（JSONL + PVC）
                                      └─ Grafana 查询

/var/log/pods ──只读 hostPath──> Alloy DaemonSet ──> Loki ──> Grafana

Git push ──> Actions（8 项测试）──> GHCR:sha-<commit> ──人工更新 values──> Git ──> Argo CD ──> demo
```

监控范围刻意排除只监听 localhost 的 etcd、scheduler、controller-manager、kube-proxy 指标端点；不创建这些不可达 target，控制面状态改由 Pod/事件观察。第一版也不采集它们的进程内指标。

## 六阶段验收状态

| 阶段 | 内容 | 实际状态 |
| --- | --- | --- |
| 1 | 集群底座：两节点 Ready、DNS、跨节点网络、Service、幂等复跑 | **33/33 PASS**；全量最终复跑 master 83 / worker 62，changed=0 both |
| 2 | 示例服务：接口、探针、指标、JSON 日志、版本、持续流量 | **8 项单元测试 + 7/7 运行验收 PASS**；镜像已由 Actions 发布到 GHCR |
| 3 | 指标与告警：主机/Pod/应用指标、规则、Grafana、通知与恢复 | **16/16 PASS**；同一 fingerprint 的 firing/resolved 已落盘 |
| 4 | 日志与持久化：两节点日志、Loki、PVC、Pod 重建后旧数据 | **日志 10/10、存储 4/4、持久化 PASS** |
| 5 | 稳定性：500、慢请求、启动失败与恢复 | **三项演练完成**；旧 Pod 在启动失败时继续服务 |
| 6 | CI/CD 与 GitOps：Actions/GHCR、Argo CD 发布、Git 回滚 | **PASS**；Actions/GHCR、Git 发布、git revert 回退、实际版本与健康均验证 |

阶段 6 已验证旧版 → 新版 → Git 回退旧版，具体提交、UTC 时间和实际接口结果见 [GitOps 验收报告](docs/gitops-acceptance.md)。2026-11-12 最终综合观测检查为 **22/22 PASS**，服务复测为 **7/7 PASS**。

## Ansible、Shell、Helm、Argo 的分工

- **Ansible**：唯一的基础设施配置入口。`site.yml` 管系统、运行时、kubeadm、Calico；`platform.yml` 以固定版本调用 Helm 安装存储、监控、日志；`gitops.yml` 安装 Argo CD 并注册 demo Application。受保护逻辑避免重复 init/join，不自动 `kubeadm reset`。
- **Shell**：做检查、验收、流量和演练。app/observability/gitops 验收只查询；cluster 验收创建临时命名空间验证跨节点网络，退出时清理。故障脚本只改 demo 及其临时同步策略；持久化演练显式 `--run` 才重建指定 Prometheus/Loki Pod。
- **Helm**：打包 kube-prometheus-stack、Loki、Alloy、Argo CD 和 demo，固定 chart/镜像版本并集中管理 values。Ansible 负责调用 Helm，不手写上游清单。
- **Argo CD**：只管理 `demo` 应用的 Git desired state，不接管平台组件。Git 是唯一发布源；`kubectl rollout undo` 或 `argocd app rollback` 不能替代 `git revert`。

更完整的解释和面试演示路径见 [docs/project-explained.md](docs/project-explained.md)。

## 版本基线

| 组件 | 固定版本 | 说明 |
| --- | --- | --- |
| Ubuntu | 22.04.5 | 目标 VM 基线 |
| Kubernetes | `1.37.2` / 包版本 `1.37.2-1.1` | 实施日稳定版 |
| Calico | `v3.33.0` | 官方清单 sha256 固定在 group_vars |
| containerd | `2.3.6-1~ubuntu.22.04~jammy` | config v3、CRI v1、systemd cgroup |
| Ansible Core | `2.21.6` | uv 管理的 Python 3.12.9，不覆盖系统 Python |
| kube-prometheus-stack | `93.2.0` | Prometheus `v3.16.0`、Alertmanager `v0.35.0` |
| Loki / Alloy | `21.2.1` / `1.15.0` | Loki 3.7.9、Alloy v1.21.3 |
| Argo CD chart | `10.17.2` | 应用镜像 `v3.6.1`，非 HA |
| Pod / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` | 与 Calico、kubeadm 一致 |

完整版本来源见 [docs/plan.md](docs/plan.md) 与 [docs/observability.md](docs/observability.md)。

## 证据索引

| 证据 | 内容 |
| --- | --- |
| [stage1-cluster.txt](docs/evidence/stage1-cluster.txt) | 33/33 PASS；包含一次 DNS `localdomain` 假阳性故障的根因与修复 |
| [stage1-idempotency.txt](docs/evidence/stage1-idempotency.txt) | 最终全量复跑：master 83 / worker 62，changed=0 both |
| [service-unit-tests.txt](docs/evidence/service-unit-tests.txt) | 8 项 unittest 全通过 |
| [stage2-service.txt](docs/evidence/stage2-service.txt) | 7/7 运行验收：探针、版本、指标、request_id |
| [storage.txt](docs/evidence/storage.txt) | local-path 4/4 PASS |
| [stage3-metrics.txt](docs/evidence/stage3-metrics.txt) | 指标与告警 16/16 PASS |
| [stage4-logging.txt](docs/evidence/stage4-logging.txt) | 两节点日志 10/10 PASS |
| [persistence.json](docs/evidence/persistence.json) | Pod UID 改变、PVC 不变；指标值 67 前后一致、旧日志精确匹配 |
| [drill-events.jsonl](docs/evidence/drill-events.jsonl) | 500/延迟/启动失败的时间线 |
| [demo-alerts.json](docs/evidence/demo-alerts.json) | Alertmanager 真实 firing/resolved webhook |
| [fault-review.md](docs/fault-review.md) | 三项演练与持久化的复盘表 |
| [gitops-acceptance.md](docs/gitops-acceptance.md) | 基线、发布、Git 回退的提交与实际版本证据 |
| [final-observability.txt](docs/evidence/final-observability.txt) | 2026-11-12 综合观测 22/22 PASS |
| [final-service.txt](docs/evidence/final-service.txt) | Git 回退后服务 7/7 PASS |
| [final-runtime.txt](docs/evidence/final-runtime.txt) | 全部 Pod Ready、两节点时间同步、内存与磁盘快照 |
| [final-cleanup.txt](docs/evidence/final-cleanup.txt) | 移除临时 sudo、恢复 apt 定时器、停止临时转发 |

故障演练实际时间（UTC）：500 于 12:16:49 开始、12:20:47 恢复；3000 ms 慢请求于 13:24:37 开始、13:28:10 恢复；启动失败于 13:34:21 开始、13:39:21 恢复，旧 Pod 持续服务。持久化演练中 Prometheus/Loki Pod UID 都改变，但沿用原 PVC，重建前指标值与日志仍可查。

## 常用命令

```bash
# 集群验收（在 master 上）
cd Full-Stack-Observability-in-Kubernetes
sudo env KUBECONFIG=/etc/kubernetes/admin.conf bash scripts/acceptance/cluster.sh

# 平台分阶段验收
sudo -E bash scripts/acceptance/observability.sh --phase storage
sudo -E bash scripts/acceptance/observability.sh --phase metrics
sudo -E bash scripts/acceptance/observability.sh --phase logging

# 持久化演练：必须显式 --run；只重建固定 Prometheus/Loki Pod，不删除 PVC
bash scripts/drills/persistence.sh --run

# 故障演练（只作用于 demo；Argo 自动同步开启时需显式暂停）
bash scripts/drills/inject.sh --fault error --suspend-gitops --alert-wait 150
bash scripts/drills/recover.sh --drill-id <drill-id>
```

`persistence.sh --run` 不带 `--run` 时会直接拒绝执行，避免误删 Pod；它不删除 PVC、不触碰其他 namespace。演练结果写入本地 `scripts/drills/logs/`，`docs/evidence/persistence.json` 是本次 PASS 的摘要。

## 访问方式（SSH 隧道，无 Ingress）

Windows 终端通过 SSH 隧道 + guest 内 port-forward 访问，不使用 NodePort/Ingress，仓库不放密码或私钥；SSH 使用密钥认证。

```powershell
ssh -L 3000:127.0.0.1:3000 myt@11.0.1.10 "kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
ssh -L 9090:127.0.0.1:9090 myt@11.0.1.10 "kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090"
ssh -L 8443:127.0.0.1:8443 myt@11.0.1.10 "kubectl -n argocd port-forward svc/argocd-server 8443:443"
```

浏览器访问 `http://127.0.0.1:3000`、`http://127.0.0.1:9090`、`https://127.0.0.1:8443`。Grafana 密码只在 master 的 `/root/.config/kube-observability/grafana-admin-password`（root 0600）读取；Argo 初始密码在 `argocd/argocd-initial-admin-secret`。两者都不得粘贴到报告、截图或 Git。

## 范围、边界与已知限制

- 两台 VM 为 master `11.0.1.10` / worker `11.0.1.11`；master 保留控制面 `NoSchedule` taint，有状态负载落在 worker。
- 时间同步最终固定为 `203.107.6.88`、`120.25.115.20`；此前 `ntp.ubuntu.com` 经代理 DNS 返回 fake-IP，曾导致约 5–6 秒偏差，两节点现均为 `NTPSynchronized=yes`。
- 监控只覆盖 node-exporter、kube-state-metrics、kubelet、API、DNS 和 demo；**不包含**只监听 localhost 的 etcd/scheduler/controller-manager/kube-proxy 指标。
- local-path 只保证 Pod 重建后 PVC/PV 仍在，不是副本存储，不防节点磁盘损坏；单 worker 没有业务高可用。
- 7 天 SLO（99.9%）是练习目标，尚未积累完整窗口，不能宣称已达标。
- Alertmanager 只验证本地 JSON webhook，不代表短信/邮件/外部聊天已接入。
- Alloy positions 未持久化，允许至少一次投递；日志保留 72h，指标 7d/8GB。
- 出网依赖宿主机代理 `11.0.1.1:7890`；关闭代理会影响 Argo 拉 Git 和新镜像下载。现有 Pod 的服务和本地采集可继续运行。

## 安全约定

- 仓库不保存 SSH 私钥、密码、token、kubeconfig、`.env` 或真实凭据。
- inventory 只保存地址与用户名；认证由执行环境提供。
- kubeadm init/join 输出使用 `no_log`；Calico 上游清单只读，CIDR 修改写入独立渲染文件。
- 不自动删除控制面 taint，不自动 `kubeadm reset`，不覆盖已存在的 `admin.conf`。

## 文档入口

- [docs/project-explained.md](docs/project-explained.md)：项目是什么、数据流、工具分工、面试演示路径。
- [docs/creation-steps.md](docs/creation-steps.md)：从虚拟机到平台的创建顺序与命令。
- [docs/plan.md](docs/plan.md)：目标、版本选择与验收设计。
- [docs/stage1-runbook.md](docs/stage1-runbook.md)：阶段 1 操作与实际验收结果。
- [docs/implementation-journal.md](docs/implementation-journal.md)：实施过程、故障修复与最终状态。
- [docs/observability.md](docs/observability.md)：监控、日志、告警、持久化配置与验收。
- [docs/demo-service.md](docs/demo-service.md)：示例服务、Chart、测试与发布。
- [docs/gitops.md](docs/gitops.md) / [docs/argocd-setup.md](docs/argocd-setup.md)：CI、Argo CD 配置；[实际发布与回退验收](docs/gitops-acceptance.md)。
- [docs/drills.md](docs/drills.md) / [docs/fault-review.md](docs/fault-review.md)：故障演练手册与复盘。
- [docs/network-proxy.md](docs/network-proxy.md)：代理、镜像与 NTP 网络说明。
