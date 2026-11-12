# 项目二接入：发布风险门禁

项目二：[k8s-change-guard](https://github.com/hey-mmm/k8s-change-guard)。项目一继续负责业务镜像、GitOps desired state 和观测平台；项目二在 master 上用独立只读身份评估发布 PR，向 GitHub 写入 `change-guard/release` 状态。

## 发布契约

1. 功能代码通过 PR 合并 main，Actions 构建并发布 GHCR 镜像。
2. 从成功的 Actions run 取得构建 commit 和镜像 manifest digest。
3. 在可信本地副本中运行发布脚本，创建修改 values 的发布 PR：

   ```bash
   HTTPS_PROXY=http://11.0.1.1:7890 \
   python3 scripts/create-release-pr.py \
     --commit <完整40位构建SHA> \
     --digest sha256:<完整64位manifest摘要> \
     --token-file <仅操作员可读的GitHub凭据文件>
   ```

   脚本核验指定 main push 的 CI 成功、build job 成功、GHCR manifest/config 摘要，以及镜像 config 的 revision/source 标签，随后创建分支和 PR；它不会直接推送 main。镜像标签仅用于定位构建，实际发布使用 digest。
4. 等待 `Test, lint, render` 与 `change-guard/release`；PASS 才可合并。REVIEW 需要按项目二报告对本次评估作显式人工确认；BLOCK/ERROR 不放行。
5. 合并 main 后 Argo CD 自动同步；核对实际镜像、Git revision、HTTP 与发布后观测证据。

服务持有的只读仓库/status 凭据不用于创建发布 PR；上面的脚本由操作员使用独立操作凭据执行。

## digest 支持

`charts/demo` 的 `image.digest` 非空时，Deployment 使用 `repository@sha256:...`；否则保留 tag 渲染兼容性。digest 必须是完整 64 位小写十六进制。门禁生产策略要求发布使用 digest，因此默认 Chart 的 tag 兼容路径不等于发布放行。

原验收脚本增加 digest 参数：

```bash
python3 scripts/acceptance/gitops.py \
  --git-revision <当前期望Git提交> \
  --image-sha <镜像构建提交> \
  --image-digest sha256:<期望manifest摘要> \
  --output /tmp/gitops-acceptance.json
```

`/version` 中的 `git_sha` 是运行时元数据，不能独自证明镜像来源；必须同时检查 Deployment 的 digest，项目二另行核对运行 Pod 的 imageID。

## 回退

从最新 main 创建分支，`git revert <发布合并提交>`，推送后创建回退 PR。回退 PR 同样经过门禁与 CI，再合并 main 等待 Argo。merge commit 的 revert 需要明确 `-m 1`；演示优先使用 squash merge 以简化单次发布的 revert。

## 文档优先级与限制

本文是项目二接入后的发布流程。`docs/gitops.md` 中直接 push main 的段落属于项目一历史创建/验收记录；启用保护后日常发布必须经过 PR。最终启用状态、真实拒绝合并结果、服务身份与验收时间以项目二的验收报告为准。

这是 GitOps 合并门禁，不能约束集群管理员直接操作 Kubernetes。单 worker 与本地 PVC 的容灾限制、七天 SLO 尚需完整数据的结论仍适用。
