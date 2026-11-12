# 实施记录（最终状态）

日期：2026-11-11 至 2026-11-12，用户时区 Asia/Shanghai。以下只记录实际执行并留有证据的事项；未完成项单独列出，不用“配置已写”代替验收。

## 1. 最终状态

| 阶段 | 结果 | 证据 |
| --- | --- | --- |
| 1 集群 | **33/33 PASS**；全量 `site.yml` 最终复跑 master **83** / worker **62** 个任务，**changed=0 both** | `evidence/stage1-cluster.txt`；`evidence/stage1-idempotency.txt` |
| 2 示例服务 | **8 项单元测试**、**7/7 运行验收 PASS**；Actions 构建、GHCR 发布成功 | `evidence/service-unit-tests.txt`、`stage2-service.txt` |
| 3 指标/告警 | **16/16 PASS**；同一 fingerprint 的 firing/resolved 已落盘 | `evidence/stage3-metrics.txt`、`demo-alerts.json` |
| 4 日志/存储 | 日志 **10/10**、local-path **4/4**、持久化 **PASS** | `evidence/stage4-logging.txt`、`storage.txt`、`persistence.json` |
| 5 故障演练 | 500、3000 ms、启动失败三项完成并恢复 | `evidence/drill-events.jsonl`、`fault-review.md` |
| 6 CI/CD/GitOps | **发布与 Git 回退 PASS**；Synced/Healthy，4 个核心 Pod 健康 | `gitops-acceptance.md`；`evidence/gitops-*.json` |

“全量复跑 changed=0 both”指 `site.yml` 最后一次执行：master 共 83 个任务、worker 共 62 个任务，两台均无 changed。完整输出已复制到 `evidence/stage1-idempotency.txt`。Argo 安装配置另行复跑 master 30 个任务，changed=0，见 `evidence/argocd-idempotency.txt`。

## 2. 虚拟机与网络

1. 两台 Ubuntu 22.04.5，VMware NAT `11.0.1.0/24`，网关/DNS `11.0.1.2`；master `11.0.1.10/24`（2 vCPU / 4 GiB / 50 GB），worker `11.0.1.11/24`（4 vCPU / 12 GiB / 100 GB）。
2. 初查根卷仅约 10 GB；用 `growpart /dev/sda 3`、`pvresize /dev/sda3`、`lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv` 扩容到约 48.2 GiB / 98.2 GiB。分区表备份在 guest `/var/backups/observability-lab/`。
3. 原清华 apt 源返回 403，且启用了 `file:///cdrom`；禁用光盘源，Ubuntu 源改为官方 archive/security，保留签名和包哈希校验。旧 Docker/Kubernetes 源移出启用配置，由 Ansible 重建固定版本源。
4. 旧 kubeadm 1.28 集群按用户授权在 playbook 之外清理；仓库不自动 `kubeadm reset`。containerd 改用 config v3、CRI v1、systemd cgroup。
5. 时间同步：`ntp.ubuntu.com` 经代理 DNS 返回 fake-IP，worker 曾偏差约 5–6 秒；改用 UDP 实际可达的 **203.107.6.88、120.25.115.20**，两节点最终 `NTPSynchronized=yes`。原始日志保留原时间，不修改历史记录。

## 3. SSH、Ansible 控制端与安全

- 通过专用 SSH 密钥连接，仓库和 inventory 不保存密码、私钥、token、kubeconfig。
- master 使用 uv 0.13.7 管理的 Python 3.12.9 和 ansible-core 2.21.6，不覆盖系统 Python 3.10；collection 安装到 `ansible/collections`（已 gitignore）。
- 部署期间临时建立 sudoers 规则并用 `visudo -cf` 校验，完成后移除；后续复跑由执行环境提供 sudo 授权。
- kubeadm init/join 输出使用 `no_log`，避免 token 进入日志；不自动删除控制面 taint。

## 4. 各阶段实际结果

### 阶段 1：集群

- `scripts/acceptance/cluster.sh`：exit 0，**33 PASS / 0 FAIL**。覆盖 `/readyz`、2 节点 Ready、containerd 2.3.6、InternalIP、控制面静态 Pod、kube-proxy/Calico/CoreDNS、Service CIDR、taint、Pod/Calico CIDR、双向跨节点 ICMP、集群 DNS、Service HTTP。
- 第一次为 32 PASS / 1 FAIL。根因不是 Service 或 kube-proxy，而是节点 `/etc/resolv.conf` 残留 `localdomain` 搜索域：四段 FQDN 的 ndots 搜索先尝试 `...cluster.local.localdomain`，被上游 fake-IP DNS 返回 `198.18.0.190`。删除该搜索域、由 systemd-resolved 重新生成后，Pod 只收到集群搜索域，复测 33/33。Ansible `common` 角色加入删除与复现失败即 fail 的检查。
- 幂等：全量 `site.yml` 最终复跑 master 83 / worker 62，changed=0 both；未重新 init/join，Calico 未重下载，节点仍 Ready。日志见 `evidence/stage1-idempotency.txt`。

### 阶段 2：示例服务

- 本机 `python -m unittest discover -s app/tests -v`：**8 项全过**，覆盖探针、`/work`、request_id、JSON 日志、指标、500/延迟注入、启动失败、非法 error rate、故障配置不可变。
- 集群运行验收：**7/7 PASS**，包括 `/healthz`、`/readyz`、`/version` 的 app_version/git_sha、`/metrics` 业务计数器/直方图、`/work` request_id、状态码计数增长、探针不写业务 SLI。
- GitHub Actions 执行 8 项测试、Helm/Shell 检查，构建并推送不可变 `sha-<commit>` 镜像到 GHCR；未使用 `latest`。

### 阶段 3：指标与告警

- `observability.sh --phase metrics`：**16/16 PASS**。
- 两节点 Ready；local-path 默认类、`WaitForFirstConsumer`、`Delete`；PVC 全部 Bound；Prometheus 19 个 active target，node-exporter 覆盖两节点，KSM 与 demo 均 up。
- 4 条 1m 演练告警、5 条记录规则、7 天 SLO 0.999；PromQL 实际查到 `demo_http_requests_total` 与延迟 bucket；Grafana 的 Prometheus/Loki 数据源和 `demo-observability` dashboard 可查。
- Alertmanager 配置含 `send_resolved: true` 和本地 webhook；receiver 有同一 fingerprint 的 `DemoHighErrorRate` firing/resolved，resolved 晚于 firing。
- 监控范围：**不采集**只监听 localhost 的 etcd、scheduler、controller-manager、kube-proxy 指标端点；不创建不可达 target。控制面状态由 Pod/事件观察。

### 阶段 4：日志与持久化

- `--phase logging`：**10/10 PASS**；Loki `/ready`，node 标签覆盖 master/worker 且两节点都有真实日志流；Alloy desired=2/ready=2，容忍 master taint，只读挂载 `/var/log/pods`；Loki PVC 10Gi Bound，PV reclaimPolicy=Delete。
- `--phase storage`：**4/4 PASS**。
- 持久化演练：`scripts/drills/persistence.sh --run`，只重建固定 Prometheus/Loki Pod，不删 PVC。Prometheus/Loki Pod UID 均改变、PVC 名称不变；重建前固定时间查询的指标值 **67**，重建后仍为 **67**；原 marker 的日志时间戳和全文精确匹配。结果 `PASS`，见 `persistence.json`。

### 阶段 5：故障演练

| 故障 | 开始 UTC | 告警 UTC | 根因确认 UTC | 恢复 UTC |
| --- | --- | --- | --- | --- |
| HTTP 500（`DEMO_ERROR_RATE=1`） | 12:16:49 | 12:18:43.140 | 12:20:45.460 | 12:20:47 |
| 慢请求 3000 ms（`DEMO_LATENCY_MS=3000`） | 13:24:37 | 13:26:43.138 | 13:28:09.558 | 13:28:10 |
| 启动失败（`DEMO_STARTUP_FAIL=true`） | 13:34:21 | 13:37:27.649 | 13:39:15.099 | 13:39:21 |

- 500：真实请求日志返回 500，触发 `DemoHighErrorRate`；恢复 200 后收到同 fingerprint resolved。
- 慢请求：日志耗时约 3.00–3.01 s，触发 `DemoP95LatencyHigh`，恢复后 resolved。
- 启动失败：新 Pod 输出 `startup_failed` 并 CrashLoop；`maxUnavailable: 0` 下旧 Pod 继续 Ready 并返回 200，触发 `DemoPodCrashLooping`。这验证滚动发布保护，不是业务全停。
- 演练中发现并修复：Service port-forward 随旧 Pod 退出；Windows 复制脚本缺执行位；Shell local 声明引用未赋值变量；旧 Pod Ready 不能证明新版本完成；Alloy 配置先 validate 再检查真实日志流。

### 阶段 6：CI/CD 与 GitOps

- Actions 构建和 GHCR 发布成功，镜像 tag 为不可变 `sha-<commit>`。
- Argo CD chart 10.17.2 已安装，**4 个核心 Pod 健康**（application-controller、repo-server、server、redis）。
- 2026-11-12 实测 Git 发布提交 `9b4f688` 将镜像切到 `10462f1`；`git revert` 产生 `60d5dea` 并 push，镜像恢复 `c0bff8a`。两个状态均 Synced/Healthy，`/version` 与期望 SHA 一致，HTTP 检查全过，见 `gitops-acceptance.md`。
- 代理重新开启后 GitHub HTTP 200；repo-server 使用代理修复 Git 拉取。回退滚动更新期间曾有一次 HTTP 超时，最终验收连续核对版本与健康通过；验收脚本对收敛使用有界重试，不将中间状态记为 PASS。
- 最终综合观测 22/22、服务 7/7 通过。
- 创建步骤复核发现 Ansible 2.21 不读取旧配置键 `collections_paths`，改为 `collections_path`；去掉临时 runner 的环境变量后，`ansible-config dump` 确认仓库 collections 路径生效，四份 playbook 语法检查通过，见 `evidence/final-static.txt`。
- 收尾已移除两节点临时 sudo 规则、恢复 apt 定时器并停止已知临时转发。两节点当前全部 Pod Ready、时间同步正常；worker 根盘使用约 17%，可用内存约 9.3 GiB。资源为单次快照，非长期容量结论。
- 正确回滚路径仍是 `git revert <bad-commit>` + push，等待 Argo sync；`argocd app rollback` 或 `kubectl rollout undo` 不能替代 Git desired state 回滚。

## 5. 仍未完成 / 不宣称

2. **7 天 SLO 达标**：规则和 0.999 目标存在，但未积累完整窗口，不宣称达标，也不编造“恢复效率提升百分比”。
3. **生产级能力**：单 worker、local-path 无副本/备份/配额/跨节点迁移；无 Ingress、证书、链路追踪、多副本高可用。
4. **通知**：只验证本地 JSON webhook，不代表短信/邮件/聊天已接入。
5. **Alloy positions**：未持久化，允许至少一次投递，不承诺 exactly-once。

## 6. 复现入口

创建顺序见 [creation-steps.md](creation-steps.md)，阶段 1 操作与结果见 [stage1-runbook.md](stage1-runbook.md)，平台配置见 [observability.md](observability.md)，故障复盘见 [fault-review.md](fault-review.md)，项目讲解见 [project-explained.md](project-explained.md)。所有验收以 [evidence](evidence/) 的原始输出为准。
