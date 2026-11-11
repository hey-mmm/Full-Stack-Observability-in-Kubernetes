# 阶段 3/4：Kubernetes 可观测性与持久化配置

本文件描述**已编写的代码和固定参数**，不代表已经部署或通过验收。当前没有在
目标 VM 上执行 `platform.yml`，没有构建/推送 demo 镜像，也没有执行 Pod 重建、
故障注入或恢复演练。实际结果必须以 `scripts/acceptance/observability.sh` 的真实
查询输出和主代理的独立验收为准。

## 1. 范围与边界

本阶段代码独占以下路径，未修改 `site.yml`、现有 roles、`group_vars`、
`charts/demo`、`scripts/traffic.sh` 或 ArgoCD 相关文件：

```text
ansible/playbooks/platform.yml
ansible/roles/platform/
platform/alert-receiver/
platform/monitoring/
scripts/acceptance/observability.sh
docs/observability.md
```

- 平台组件由 Ansible + Helm 管理；ArgoCD **未实现**，留待阶段 6。
- master `11.0.1.10` 保留控制面 `NoSchedule` taint，只运行 node-exporter 和
  Alloy 等 DaemonSet；有状态组件调度到 worker `11.0.1.11`。
- local-path 只保证 **Pod 重建后 PVC/PV 仍在**。它不是副本存储，也不防节点
  磁盘损坏；单 worker 失效时 Prometheus/Loki 数据不可用。
- Grafana 初始通过 `kubectl port-forward` 访问，不使用 Ingress/证书。
- 告警接收端是集群内的**演示用 JSON webhook**，不发送邮件、不接入外部聊天，
  也不宣称具备生产通知可靠性。

## 2. 版本固定与来源

核实日期：2026-11-11。以下版本均来自上游发布元数据，不使用 `latest`。

| 组件 | Helm chart | app / 镜像版本 | 上游依据 |
| --- | --- | --- | --- |
| kube-prometheus-stack | `93.2.0` | Operator `v0.95.2` | [Chart.yaml](https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/Chart.yaml)，GitHub release `kube-prometheus-stack-93.2.0`（2026-11-11） |
| Prometheus | 包含于上述 chart | `v3.16.0-distroless` | chart `prometheus.prometheusSpec.image` 默认值，在本仓库显式固定 |
| Alertmanager | 包含于上述 chart | `v0.35.0` | chart `alertmanager.alertmanagerSpec.image` |
| Prometheus Operator | 包含于上述 chart | `v0.95.2` | chart appVersion 与默认镜像 |
| node-exporter | 子 chart `5.1.0` | `v1.12.1-distroless` | 子 chart `Chart.yaml` appVersion、chart 默认 distroless |
| kube-state-metrics | 子 chart `9.0.0` | `v2.20.0` | 子 chart `Chart.yaml` appVersion |
| Grafana | 子 chart `14.4.1` | `13.3.1-distroless` | 子 chart `Chart.yaml` appVersion |
| Loki | `21.2.1` | `3.7.9` | [grafana-community Chart.yaml](https://raw.githubusercontent.com/grafana-community/helm-charts/main/charts/loki/Chart.yaml)；OSS chart 已迁移到 grafana-community |
| Alloy | `1.15.0` | `v1.21.3` | [alloy Chart.yaml](https://raw.githubusercontent.com/grafana/helm-charts/main/charts/alloy/Chart.yaml) / release `alloy-1.15.0` |
| local-path-provisioner | 无 Helm，官方清单 `v0.0.37` | `v0.0.37` | [官方 manifest](https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml)，sha256 `9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65` |
| Kubernetes | — | `v1.37.2` | 项目已批准基线；本角色只校验，不升级/重建 |
| Calico | — | `v3.33.0` | 阶段 1 已有配置，本阶段不修改 |

兼容性说明：

- kube-prometheus-stack `93.2.0` 的 `kubeVersion` 为 `>=1.25.0-0`；Loki
  `21.2.1` 的 `kubeVersion` 为 `>=1.25.0-0`。Kubernetes `1.37.2` 满足这些
  上游约束。该结论来自 chart 元数据，**不是**对每个镜像在本实验室的独立认证；
  必须由真实部署验收确认。
- Loki chart 21.x 把原来的 `SingleBinary` 模式改名为 `Monolithic`
  （`deploymentMode: Monolithic`），工作负载仍使用 `singleBinary` 块。
- Grafana 使用上游 chart 自带的 Prometheus datasource（sidecar 生成），
  额外数据源由 `additionalDataSources` 增加 Loki；没有手写不存在的指标。

## 3. 组件、资源、保留期与 PVC

所有资源都在 values 文件中显式设置，便于评审。控制器/临时 sidecar 的少量
资源另计；下表的合计仅用于判断单 worker 12 GiB 是否可行。

| 组件 | requests | limits | 持久化 | 保留/说明 |
| --- | --- | --- | --- | --- |
| Prometheus | `500m / 1Gi` | `1 CPU / 2Gi` | `local-path` `10Gi` | `7d`，`retentionSize: 8GB` |
| Alertmanager | `50m / 64Mi` | `250m / 256Mi` | `local-path` `1Gi` | `retention: 72h` |
| Grafana | `100m / 128Mi` | `300m / 512Mi` | `local-path` `2Gi` | 含 Loki/Prometheus datasource 与 demo dashboard |
| Prometheus Operator | `50m / 64Mi` | `200m / 256Mi` | 无 | admission webhook 关闭，减少证书/Patch Job |
| node-exporter | `30m / 32Mi` × 2 | `150m / 128Mi` × 2 | 无 | 两节点 DaemonSet，显式容忍 master taint |
| kube-state-metrics | `30m / 64Mi` | `150m / 192Mi` | 无 | 单副本，调度到 worker |
| Loki singleBinary | `200m / 512Mi` | `500m / 1Gi` | `local-path` `10Gi` | `72h`，compactor 实际清理 filesystem |
| Alloy | `50m / 64Mi` × 2 | `200m / 192Mi` × 2 | 无 | 两节点日志 DaemonSet |
| local-path provisioner | `20m / 32Mi` | `100m / 128Mi` | 使用节点盘 | 官方清单后做资源补丁 |
| alert-receiver | `20m / 32Mi` | `100m / 128Mi` | `local-path` `1Gi` | JSONL 告警事件，单副本 |

只计算上表主容器及显式 sidecar，平台请求约为 **1.18 vCPU / 2.19 GiB**，
limits 约为 **3.65 vCPU / 5.5 GiB**。相对单 worker 的 4 vCPU / 12 GiB，
留有控制面和突发余量；但 limits 不是硬性总预算，仍需观察实际使用。

PVC 合计 **24Gi**（Prometheus 10 + Loki 10 + Grafana 2 + Alertmanager 1 +
receiver 1），位于 worker 的 `/opt/local-path-provisioner` 所在磁盘。local-path
的 `10Gi` 只是 PVC 请求/绑定大小，**不是文件系统配额**；日志或指标写满宿主盘
仍会影响 worker。没有实现磁盘配额、备份、跨节点复制或快照。

Prometheus：
- `retention: 7d` 与 `retentionSize: 8GB` 同时设置；8GB 小于 10Gi PVC，留出
  WAL/压缩余量。
- 实际保留可能先被时间或大小任一条件触发，不能宣称必然保留满 7 天。

Loki：
- `schema: v13`，`store: tsdb`，`object_store: filesystem`，
  `replication_factor: 1`。
- `retention_period: 72h`；`compactor.retention_enabled: true`；
  `compactor.delete_request_store: filesystem`；compactor 的 working directory
  为 `/var/loki/compactor`。
- 关闭 gateway、chunks cache、results cache、memcached 和 canary，避免额外
  常驻副本；没有对象存储，所有数据在本地 PVC。

## 4. ServiceMonitor 与规则

demo Chart **不修改**。安装/升级 demo 时需要显式启用：

```bash
helm upgrade --install demo charts/demo -n observability \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.labels.release=monitoring
```

平台 values 将 Prometheus 的 `serviceMonitorSelectorNilUsesHelmValues`、
`ruleSelectorNilUsesHelmValues` 设为 `false`，并显式使用空的命名空间选择器，
因此可以选中 demo 自带的 ServiceMonitor（`release=monitoring`）和本阶段的
`PrometheusRule`。ServiceMonitor 仍只选择 demo 自己 namespace 的 Service。

规则文件 `platform/monitoring/prometheus-rules-demo.yaml`：

- 告警（`for: 1m`，用于演练，不是生产 burn-rate）：
  - `DemoHighErrorRate`：`/work` 的 1 分钟 5xx 比例 > 5%，且总流量 > 0；
  - `DemoP95LatencyHigh`：`histogram_quantile(0.95, ...)` > 0.5s；
  - `DemoUnavailable`：`absent(up{namespace="observability"})` 或所有目标
    `up == 0`；
  - `DemoPodCrashLooping`：`kube_pod_container_status_restarts_total` 在 10 分钟
    内增加 > 3。
- 7 天 SLI/SLO 记录：
  - `demo:sli_availability:ratio_7d`；
  - `demo:http_errors:ratio_5m`、`demo:http_requests:rate_5m`；
  - `demo:slo_target:ratio = 0.999`；
  - `demo:slo_error_budget:ratio_7d = availability - 0.999`。
- 可用性/错误率记录使用 `and on() (total_rate > 0)` 去除无流量时的除零结果，
  不会在无流量时显示误导性的 100%。7 天目标 `99.9%` 是练习目标，不是已达成
  的实测结果。

## 5. Grafana

- 数据源：Prometheus（chart 默认，uid 通常为 `prometheus`）和 Loki
  （`http://loki.logging.svc.cluster.local:3100`，uid `loki`）。
- Dashboard JSON：`platform/monitoring/dashboards/demo-observability.json`，
  uid `demo-observability`。包含：
  - 7d 可用性与 99.9% SLO/错误预算；
  - 请求速率（按 status）、5xx 错误率、P95 延迟；
  - 版本/Pod/节点表（`kube_pod_container_info` + `kube_pod_info`，版本使用
    镜像 tag，不虚构应用版本指标）；
  - 两节点 CPU/内存；
  - Loki 业务日志面板和日志链接。`request_id` 只留在 JSON 正文，不作为标签。
- Dashboard 通过带 `grafana_dashboard=1` 的 ConfigMap 由 sidecar 加载，JSON
  是唯一源文件；Ansible 只从该文件生成 ConfigMap。

Grafana admin 密码：

1. master 上首次生成随机密码，文件为
   `/root/.config/kube-observability/grafana-admin-password`，root `0600`；
2. 同步到 Kubernetes Secret `monitoring/grafana-admin`，Grafana chart 用
   `admin.existingSecret` 引用；
3. 不写入仓库、values 文件、报告或命令输出。验收脚本读取该 Secret 调用
   Grafana API，但不打印密码。

查看密码（仅由有 root 权限的操作者按需执行，不粘贴到报告）：

```bash
sudo cat /root/.config/kube-observability/grafana-admin-password
```

## 6. Alertmanager 与本地 JSON receiver

`kube-prometheus-stack` values 中配置：

```yaml
route:
  receiver: lab-json-webhook
receivers:
  - name: lab-json-webhook
    webhook_configs:
      - url: http://alert-receiver.monitoring.svc.cluster.local:8080/alerts
        send_resolved: true
```

接收端 `platform/alert-receiver/`：

- `python:3.13.9-slim-bookworm` 固定镜像，直接运行 ConfigMap 中的标准库
  `ThreadingHTTPServer` 脚本；无需构建自定义镜像。
- Deployment 单副本，`Recreate`，JSONL 写入 PVC
  `monitoring/alert-receiver-data`（1Gi，local-path）；每条事件带 UTC
  `received_at`、groupKey 和原始 alert。
- 接口：
  - `POST /alerts`：Alertmanager webhook；
  - `GET /alerts?limit=50`：最近事件；
  - `GET /healthz`：健康检查。
- ClusterIP 内部使用，无认证；它是演示接收端，不具备高可用、去重、签名验证、
  外发通知或长期归档保证。单 worker/单 PVC 故障会丢失接收端数据；JSONL 未做
  自动轮转，长时间运行应注意 PVC 使用量。

## 7. Alloy 日志采集

- DaemonSet 固定 `grafana/alloy:v1.21.3`，`tolerations: [{operator: Exists}]`，
  因此在 master 和 worker 都运行。
- 只挂载宿主 `/var/log/pods` 到容器 `/var/log/pods`（readOnly），不挂
  `/var/lib/docker`，不使用 hostPath 写入。
- `discovery.kubernetes "pods"` 发现 Pod，`discovery.relabel` 生成
  `namespace`、`pod`、`node`、`container` 标签和 `__path__`；随后
  `labeldrop "__meta_.*"` 丢弃其余发现元数据。
- `loki.source.file` 读取 `/var/log/pods/*<uid>/<container>/*.log`，
  `loki.write` 推送到 Loki。JSON 中的 `request_id` 不被解析成标签。
- 采集覆盖两节点 Pod 日志；Pod 删除后对应日志文件可能轮转/删除，Loki 保留
  期限为 72h，但实际可查范围受采集开始时间和 PVC 容量限制。

## 8. 执行顺序与命令行

以下命令都应在 master 的仓库根目录、使用阶段 1 已准备好的 Ansible 环境执行。
本阶段没有在本机运行它们；不要在没有逐步验收的情况下一次运行全部。

```bash
cd ansible

# 1) 动态存储；preflight 总会先校验 K8s 1.37.2、两节点 Ready 和 Helm
ansible-playbook playbooks/platform.yml --tags storage
cd ..
bash scripts/acceptance/observability.sh --phase storage

# 2) 指标、告警、Grafana、receiver
#    先确保 demo 已按第 4 节启用 ServiceMonitor
cd ansible
ansible-playbook playbooks/platform.yml --tags metrics
cd ..
# 产生真实 /work 流量并完成一次错误/延迟/不可用演练后：
bash scripts/acceptance/observability.sh --phase metrics

# 3) Loki + Alloy
cd ansible
ansible-playbook playbooks/platform.yml --tags logging
cd ..
bash scripts/acceptance/observability.sh --phase logging
```

`--tags storage/metrics/logging` 不会隐式删除或重建已有组件。preflight 只读；
Helm 使用固定 `--version`、`wait=true` 和超时；`kubectl apply` 的
`changed_when` 根据 `created/configured/unchanged` 判断。local-path 官方清单
按 URL + sha256 下载并缓存，之后仅做幂等 apply；当前代码额外补了 Provisioner
容器 requests/limits，并把 local-path 标记为默认 StorageClass。

## 9. 验收脚本实际检查什么

`scripts/acceptance/observability.sh` 默认只读，不执行 delete/restart/apply/
patch。它通过 kubectl 只读查询和临时 port-forward 真实访问 API：

- **所有阶段**：两节点 Ready、控制面 `NoSchedule` taint 存在。
- **storage**：
  - `local-path` 为默认 SC，`WaitForFirstConsumer`、`ReclaimPolicy Delete`；
  - provisioner Deployment 可用；
  - 若 PVC 已存在，则必须 Bound、storageClass 正确、PV reclaimPolicy Delete。
- **metrics**：
  - Prometheus `/api/v1/targets` 中 node-exporter 至少 2 个健康目标且覆盖两个
    节点，KSM 健康，`observability` namespace 的 demo target 健康；
  - 实际 PromQL 查询到 `demo_http_requests_total{route="/work"}` 和
    `demo_http_request_duration_seconds_bucket{route="/work"}` 样本；
  - `demo-slo`/`demo-alerts` 规则组存在，4 个 1m 演练告警和 5 个记录规则存在，
    可用性规则包含无流量 guard；
  - Alertmanager 实际配置 Secret 中 `send_resolved: true` 且 webhook URL 指向
    `alert-receiver`；
  - receiver `/alerts` 至少有一条真实事件且 `received_at` 为 UTC；默认没有事件
    即失败（`--allow-empty-alerts` 仅用于 smoke，不能作为最终验收）；
  - Grafana API 数据源包含 `prometheus` 和 `loki`，dashboard
    `uid=demo-observability` 返回 200。
- **logging**：
  - Loki `/ready`；
  - Loki `node` label values 覆盖两个实际节点名，且对每个 node 的
    `query_range` 都返回真实日志流；
  - Alloy DaemonSet desired/ready ≥2，无 nodeSelector，有 Exists 容忍，
    `/var/log/pods` 为只读 hostPath；
  - Loki PVC 10Gi Bound，PV reclaimPolicy Delete。

脚本**不会**自动删除 Prometheus/Loki Pod，也不会执行数据重建。持久化和故障
重建演练由主代理在验收窗口单独执行；脚本只在演练完成后验证查询结果和事件。
脚本要求 demo 已经产生过真实流量，否则 metrics 阶段会明确失败而不是伪造数据。

手工查看 Grafana：

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# 浏览器打开 http://127.0.0.1:3000，用户名 admin
# 密码从 root 0600 文件读取，不要打印到报告
```

手工查看 receiver：

```bash
kubectl -n monitoring port-forward svc/alert-receiver 8080:8080
curl -s 'http://127.0.0.1:8080/alerts?limit=5'
```

## 10. 未完成、风险与待验证项

- **未部署、未验收、未 push**。本文中的资源合计和版本兼容性是静态评审结果。
- 未构建/扫描/推送 demo 镜像；`charts/demo/values.yaml` 的镜像仓库仍是占位值。
  ServiceMonitor 只有在 demo 实际安装且 `serviceMonitor.enabled=true`、
  `serviceMonitor.labels.release=monitoring` 时才存在。
- 未执行 Prometheus/Loki Pod 重建、PVC 重建、节点故障或任何真实告警演练；
  receiver 事件为空时脚本会失败。
- 现有 `ansible/group_vars/all.yml` 的 `control_plane_endpoint` 仍是
  `11.0.1.129:6443`，而本任务给定的 master 固定地址是 `11.0.1.10`；本阶段
  未修改 group_vars，需由 group_vars 的维护者在阶段 1/2 收口。平台角色只使用
  `kubeconfig_path` 和节点名称，不自行改网络配置。
- 现有 group_vars 的保留期/PVC 值（Prometheus 10Gi、Loki 20Gi、Alertmanager
  2Gi、Grafana 5Gi）与本阶段平台 values（10Gi、10Gi、1Gi、2Gi）不同。为避免
  覆盖其他任务的变量，平台采用独立的 `ansible/roles/platform/vars/main.yml`；
  以平台 values 为准，但这需要在总体验收时明确，避免误读。
- local-path 官方 v0.0.37 清单自带的 helper Pod 使用未固定 tag 的
  `docker.io/library/busybox`。本阶段固定了 provisioner 版本和清单 checksum，
  但没有修改上游 helper Pod 镜像；这是复现性/供应链上的已知缺口。
- 单 worker + local-path 没有磁盘配额、备份、跨节点迁移、HA 或灾难恢复。
  master 只有 4 GiB，未把 Prometheus/Loki/Grafana 调度到 master；实际启动
  仍需观察 worker 内存和 `/opt/local-path-provisioner` 磁盘。
- Alertmanager 的 receiver 只做本地 JSONL 记录，没有认证、TLS、external
  notification 或可靠投递保证；不能把“收到 webhook”等同于“发送了邮件/聊天”。
- Grafana Loki dashboard 链接和 Explore URL 随 Grafana 版本可能变化；JSON
  中的日志面板使用 datasource uid `loki`，若实际 uid 不同需在 Grafana 中调整。
- 本阶段没有 ArgoCD。GitOps 只管理 demo 应用是后续阶段范围。
