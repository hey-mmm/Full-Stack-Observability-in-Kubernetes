# 项目讲解：从裸机到可观测性平台

本文用一页讲清项目做什么、数据怎么流、工具为什么这样分工，以及在面试中如何用真实证据演示。验收数字和原始记录以 [README](../README.md) 与 [evidence](evidence/) 为准。

## 1. 一句话说明

在 VMware 的两台 Ubuntu 虚拟机上，用 Ansible 建立 1 master + 1 worker 的 Kubernetes 集群，部署带指标/日志/故障注入的示例服务，再叠加 Prometheus、Alertmanager、Grafana、Loki、Alloy 和 local-path，最后用 GitHub Actions + GHCR + Argo CD 管理 demo 的镜像发布。项目交付的是**可重复部署 + 可验证观测 + 可复盘恢复**，不是一套“脚本跑通”的截图。

## 2. 数据流

1. **请求**：用户或 `scripts/traffic.sh` 访问 demo Service，进入 `/work`。
2. **指标**：demo 在 `/metrics` 暴露请求计数和延迟直方图；Prometheus 通过 ServiceMonitor 抓取。node-exporter 提供两节点主机指标，kube-state-metrics 提供 Kubernetes 对象状态，kubelet/API/DNS 提供运行时与集群服务指标。
3. **规则与告警**：Prometheus 计算 5xx 比例、P95 延迟、目标可用性和 7 天 SLI/SLO；Alertmanager 将 firing/resolved 发给集群内 `alert-receiver`，事件带 fingerprint 落到 JSONL + PVC。
4. **日志**：容器 stdout 写到节点 `/var/log/pods`；Alloy DaemonSet 以只读 hostPath 采集，推送到 Loki；Grafana 用 Prometheus + Loki 两个数据源展示。
5. **存储**：Prometheus、Loki、Grafana、Alertmanager、receiver 使用 local-path PVC。Pod 重建后 PVC 保留，但节点磁盘损坏会丢数据。
6. **发布**：push main 触发 Actions 的 8 项测试、Helm/Shell 检查，构建 `ghcr.io/...:sha-<commit>`；人工把 SHA 写入 `gitops/demo/values.yaml`，Argo CD 从 Git 同步到 demo。基础平台不由 Argo 管理。

## 3. Ansible、Shell、Helm、Argo 各管什么

| 工具 | 负责 | 不负责 | 本项目的证据 |
| --- | --- | --- | --- |
| Ansible | 系统基线、NTP、内核、swap、containerd、kubeadm、Calico、Helm 安装平台、Argo 安装 | 不代替验收，不自动 reset，不直接改 GitOps 期望状态 | 全量复跑 master 83 / worker 62，changed=0 both |
| Shell | preflight、只读验收、流量、故障注入/恢复、持久化演练 | 不做配置管理，不静默删除资源 | 33/33、7/7、16/16、10/10、4/4、演练时间线 |
| Helm | 固定 chart/镜像版本，渲染 kube-prometheus-stack、Loki、Alloy、Argo CD、demo | 不决定何时部署，不替代 GitOps | chart 版本与 values 固定在 `ansible/roles/platform`、`ansible/roles/argocd` |
| Argo CD | 只同步 Git 中的 demo 期望状态，支持 Git 回滚 | 不管平台组件；进程健康 ≠ 应用已验收 | **发布与 Git 回退 PASS**；Synced/Healthy，实际版本一致 |

关键边界：**Ansible 管“平台怎么装”，Helm 管“组件怎么渲染”，Shell 管“事实是否通过”，Argo 管“应用期望状态从 Git 来”**。四者不能互相替代，尤其不能用 `kubectl rollout undo` 冒充 GitOps 回滚。

## 4. 实际验收结果

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 集群 | 33/33 PASS；DNS、跨节点 Pod 网络、Service HTTP 均验证 | `docs/evidence/stage1-cluster.txt` |
| 幂等 | 全量最终复跑 master 83 / worker 62，changed=0 both | `stage1-idempotency.txt` |
| 示例服务 | 8 项单元测试；7/7 运行验收 | `service-unit-tests.txt`、`stage2-service.txt` |
| 存储 | 4/4 PASS；local-path 默认类、PVC Bound | `storage.txt` |
| 指标/告警 | 16/16 PASS；同一 fingerprint 的 firing/resolved | `stage3-metrics.txt`、`demo-alerts.json` |
| 日志 | 10/10 PASS；两节点均有真实日志流 | `stage4-logging.txt` |
| 故障演练 | 500、3000 ms、启动失败均完成并恢复 | `drill-events.jsonl`、`fault-review.md` |
| 持久化 | PASS；Prometheus/Loki UID 改变、PVC 不变、旧数据可查 | `persistence.json` |
| GitOps | **PASS**；Git 发布和 revert 后实际服务版本均匹配 | `gitops-acceptance.md`、`gitops-publish.json`、`gitops-rollback.json` |

## 5. 面试演示路径（约 5 分钟）

**第 1 分钟：讲问题和边界。** 两台 VM、单 worker、local-path，所以不宣称高可用；监控不含 localhost-only 的 etcd/scheduler/controller-manager/kube-proxy；GitOps 只覆盖 demo，发布与 Git 回退已验证。先讲限制，后面每个结论才可信。

**第 2 分钟：打开 README 状态表和 evidence。** 指出 33/33、8+7、4/4、16/16、10/10；再打开 `stage1-idempotency.txt` 说明“第二次运行 changed=0”才是幂等，不是“第一次成功”。

**第 3 分钟：讲一次真实故障。** 打开 `fault-review.md`：500 从 12:16:49Z 开始，12:18:43Z 收到告警，12:20:45Z 确认根因，12:20:47Z 恢复；同一 fingerprint 有 resolved。再讲启动失败时新 Pod CrashLoop、旧 Pod 仍 Ready——这是发布保护，不是全站故障。

**第 4 分钟：讲持久化。** 打开 `persistence.json`：Prometheus/Loki Pod UID 变了，PVC 没变，固定查询的指标值 67 前后一致，旧日志时间戳和全文精确匹配。强调“只看新 Pod Running 不能证明数据没丢”。

**第 5 分钟：讲发布与诚实结论。** Actions 产出不可变 `sha-<commit>`，Argo 从 Git 取期望状态；Git 回滚应 `git revert` 后 push。打开 `gitops-acceptance.md`，展示 `9b4f688` 发布与 `60d5dea` 回退：实际 `/version` 从 c0bff8a → 10462f1 → c0bff8a，两次均 Synced/Healthy。下一步是积累完整 7 天 SLO 窗口，再评估多 worker/备份。

如果现场有集群，可只读演示：

```bash
kubectl get nodes -o wide
kubectl -n monitoring get pods
kubectl -n demo get deploy,pods -o wide
sudo -E bash scripts/acceptance/observability.sh --phase metrics
```

如果现场没有集群，就用 evidence 文件和时间线，不口头编造“我刚跑过”。UI 演示用 SSH 隧道，不用 NodePort/Ingress：

```powershell
ssh -L 3000:127.0.0.1:3000 myt@11.0.1.10 "kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
```

浏览器打开 `http://127.0.0.1:3000`。密码只在 master 的 root 0600 文件或 Kubernetes Secret 中读取，不放进仓库、终端历史或截图。

## 6. 容易被追问的点

- **为什么用 Ansible 又用 Helm？** Ansible 管节点与安装顺序，Helm 管复杂组件的版本化渲染；让 Ansible 直接维护上千行上游 YAML 不可审计。
- **为什么 Shell 不是配置管理？** Shell 只做验收和演练，默认只读；把“检查”与“修改”分开，失败时不会顺手改坏集群。
- **为什么 Argo 只管 demo？** 平台组件需要节点级权限和安装顺序，交给 Ansible/Helm 更合适；Argo 管应用可以让发布和回滚都由 Git 审计。
- **NTP 为什么写死 IP？** `ntp.ubuntu.com` 经代理 DNS 返回 fake-IP，导致约 5–6 秒偏差；改为 UDP 可达的 `203.107.6.88`、`120.25.115.20` 后两节点 `NTPSynchronized=yes`。
- **持久化脚本怎么跑？** `bash scripts/drills/persistence.sh --run`。必须显式 `--run`，否则拒绝执行；只重建固定 Prometheus/Loki Pod，不删 PVC。
- **SLO 达标了吗？** 没有。99.9% 是练习目标，尚未积累完整 7 天窗口，不能把规则存在当成达标。
