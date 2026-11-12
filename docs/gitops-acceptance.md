# GitOps 发布与 Git 回退验收

2026-11-12 在真实两节点集群完成，结果 **PASS**。这是 Git 变更驱动的发布与回退：没有用 `kubectl rollout undo` 代替 Git 回退。时间使用 UTC，北京时间加 8 小时。

## 提交、镜像与实际版本

| 阶段 | Argo 同步的 Git 提交 | 实际镜像 SHA / `/version.git_sha` | 验收时间 UTC | 结果 |
| --- | --- | --- | --- | --- |
| 基线 | `10462f1a5cedaf8466fd1dc85f8c788eb4059496` | `c0bff8abf5625903e5b9b19b586e9660b9fe7a8c` | 00:53:25 | PASS |
| 发布 | `9b4f6884d4f2fdceb32df8b08005a93d18952b24` | `10462f1a5cedaf8466fd1dc85f8c788eb4059496` | 00:58:50 | PASS |
| Git 回退 | `60d5deae28eacc452535ed1b36db243fa2bb9505` | `c0bff8abf5625903e5b9b19b586e9660b9fe7a8c` | 01:04:17 | PASS |

发布提交只改 `gitops/demo/values.yaml` 的 image.tag、gitSha、appVersion。回退执行：

```bash
git revert --no-edit 9b4f6884d4f2fdceb32df8b08005a93d18952b24
git push origin main
```

镜像来源是 Actions/GHCR，而非 VM 临时构建：

- [10462f1 构建成功](https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes/actions/runs/43031692016)
- [发布提交 CI 成功](https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes/actions/runs/43130647015)
- [回退提交 CI 成功](https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes/actions/runs/43131384309)

Git 配置提交与镜像构建提交不同：例如 `9b4f688` 选择部署 `10462f1` 构建的镜像。后续文档提交同样不会自动把新构建镜像发布到应用。

## 实际核验内容

使用 [gitops.py](../scripts/acceptance/gitops.py) 读取真实 API 与服务接口：

- Application 的 Git revision 精确匹配，状态 `Synced / Healthy`。
- Deployment 镜像为完整 SHA tag；`/version` 返回相同 Git SHA。
- `/healthz`、`/readyz`、`/work` 均 HTTP 200。
- 四个 Argo 核心 Pod Ready；自动 prune/selfHeal 均启用。
- AppProject 只允许本仓库、demo namespace 及三种应用资源，禁止 cluster-scoped 写入。

原始 JSON：[基线](evidence/gitops-baseline.json)、[发布](evidence/gitops-publish.json)、[回退](evidence/gitops-rollback.json)。回退后服务完整验收 [7/7 PASS](evidence/final-service.txt)，综合观测验收 [22/22 PASS](evidence/final-observability.txt)。Argo 安装配置复跑 [changed=0](evidence/argocd-idempotency.txt)。

回退滚动更新期间一次即时 HTTP 检查超时，未记为通过；最终等待收敛后实际版本及所有接口均通过。验收脚本对 Service 收敛使用 90 秒有界重试，超时仍会失败。

## 运行边界

repo-server 通过宿主机 `http://11.0.1.1:7890` 访问 GitHub，代理已复测 HTTP 200。关闭代理会影响 Git 拉取和新镜像下载；已运行的服务与本地监控不依赖持续访问 GitHub。重建到直连网络时，同时调整 containerd 代理变量和 Argo `repoServer.env`。

基础组件由 Ansible 管理，GitOps 只管理 demo。故障演练需 `--suspend-gitops`，恢复脚本还原原自动同步策略，避免 selfHeal 提前修复注入故障。当前 demo 已恢复正常配置，未保留故障。

还实际核验了演练保护：未提供 `--suspend-gitops` 时脚本明确拒绝，Deployment 和 Application generation 均保持不变，见 [gitops-drill-guard.txt](evidence/gitops-drill-guard.txt)。两节点临时 sudo 规则已删除、apt 定时器已恢复，见 [final-cleanup.txt](evidence/final-cleanup.txt)。
