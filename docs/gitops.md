# CI 与 GitOps 交付说明

本目录只描述和准备 CI/Argo CD 代码，**不部署、不 SSH、不提交、不 push**。
Argo CD 本身的 Helm 安装由主代理后续实现。仓库：
`github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes`。

## 1. 镜像与 CI

- CI：`.github/workflows/ci.yml`
- 可复用 Helm 安装 action：`.github/workflows/actions/setup-helm/action.yml`
- 镜像：`ghcr.io/hey-mmm/observability-demo`
- push `main` 的 tag：`ghcr.io/hey-mmm/observability-demo:sha-${GITHUB_SHA}`
  （完整 40 位 commit，**不生成 latest**）
- PR：只运行测试/Helm 渲染/Shell 语法，不登录 GHCR、不构建、不推送。
- `main` push：测试通过后构建并推送，并把 tag/digest 写入 GitHub Step Summary。
- workflow **不会**自动修改 `gitops/demo/values.yaml`、不会 `git push`，避免 CI
  提交触发自身形成循环。构建成功后由人工/主代理更新 GitOps desired state。

### Action 固定版本

以下完整 commit SHA 于 2026-11-11 通过 GitHub 官方 tags API 核实，并在 workflow
中以注释保留可读 tag：

| Action | 版本 | 完整 commit SHA |
| --- | --- | --- |
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/setup-python` | v7.1.0 | `6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` |

`permissions` 最小化：

- workflow 顶层仅 `contents: read`；
- `test` job 无额外权限；
- 只有 `build` job 在 push main 时申请 `packages: write`，用于 GHCR 推送。

### Helm 3 固定与校验

- 版本：**v3.22.1**（2026-10-15 发布，Helm 3 当前受支持 patch）。
- Linux amd64 tar.gz 官方 SHA256：
  `896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea`
- 本地 composite action 下载固定 URL，`sha256sum --check --strict` 通过后才
  `install` 到 `/usr/local/bin/helm`，然后打印 `helm version --short`。
- 不下载 `latest`，不依赖未固定的第三方 setup action。

### 构建参数

workflow 实际传入：

- `--build-arg APP_VERSION=0.1.0-${GITHUB_SHA}`
- `--build-arg GIT_SHA=${GITHUB_SHA}`

并增加 `org.opencontainers.image.revision/source/version` labels。

> **当前阻塞项（必须由 Dockerfile owner 处理）**：仓库现有 `app/Dockerfile`
> 尚未声明 `ARG APP_VERSION` / `ARG GIT_SHA`。workflow 已按契约传入这两个
> build arg，并在 build job 中强制校验；缺失时**拒绝构建/推送**（不是静默警告）。
> 在 Dockerfile 增加对应 `ARG`（以及需要时的 `ENV`）之前，CI 不会产出镜像。
> 运行时 `/version` 仍由 Helm env 注入 `APP_VERSION/GIT_SHA`，但这不等于镜像
> 构建元数据已固化；CI 不会伪造这个结果。

## 2. Argo CD Application / AppProject

文件：

- `gitops/argocd/project.yaml`
- `gitops/argocd/application.yaml`
- `gitops/demo/values.yaml`

关键属性：

- Application 名：`demo`，Argo namespace：`argocd`。
- AppProject：`demo`。
- `source.repoURL`：本仓库 HTTPS URL。
- `source.targetRevision: main`（Git 分支；GitOps 不以镜像 latest 浮动）。
- `source.path: charts/demo`。
- `source.helm.valueFiles: ../../gitops/demo/values.yaml`（相对 chart 目录解析到
  仓库根 `gitops/demo/values.yaml`）。
- destination：`https://kubernetes.default.svc` / namespace `demo`。
- `syncPolicy.automated`：`prune: true`、`selfHeal: true`，默认启用。
- 不设置 `CreateNamespace`；**namespace `demo` 必须预先存在**，因为 AppProject
  禁止所有 cluster-scoped 资源（`clusterResourceWhitelist: []`）。
- AppProject 只允许本仓库、只允许 server `https://kubernetes.default.svc` 的
  `demo` namespace；只放行 Deployment、Service、ServiceMonitor 三种
  namespace-scoped 类型。
- 不管理 Namespace、CRD、ClusterRole、Ingress、NodePort 等。

因此 Argo “只管 demo”，不会借 project 部署到其它 namespace，也不能创建
cluster-scoped 资源。

## 3. GitOps 镜像占位（必须先更新）

`gitops/demo/values.yaml` 当前是**明确的占位值**：

```yaml
image:
  repository: ghcr.io/hey-mmm/observability-demo
  tag: "sha-REPLACE_WITH_ACTUAL_IMMUTABLE_TAG"
appVersion: "0.1.0"
gitSha: "REPLACE_WITH_ACTUAL_GIT_SHA"
```

现有 `charts/demo` 只支持 `image.repository + image.tag`，**尚不支持
`image.digest`**。因此：

1. 在 chart 增加 digest 支持前，tag 必须是不可变的 `sha-<完整40位commit>`；
2. 禁止填 `latest`、`main` 或可移动 tag；
3. 构建成功后从 CI summary 取得实际 tag/digest，替换占位；
4. 若后续 chart 支持 digest，应优先改用 digest，并保留注释说明。

**在占位未替换前不要 apply/sync Application**，否则镜像拉取会失败。不要用
占位值宣称服务已可运行。

### 构建后人工更新流程

```bash
# 1) 等 CI 的 Build and push image 成功
# 2) 在 Step Summary 找到 tag，例如：
#    ghcr.io/hey-mmm/observability-demo:sha-<40 hex>
# 3) 编辑 gitops/demo/values.yaml
#    image.tag: sha-<40 hex>
#    appVersion: 与 CI 的 APP_VERSION 对齐
#    gitSha: <40 hex>
# 4) 提交 desired state（人工/主代理）
git add gitops/demo/values.yaml
git commit -m "gitops: deploy demo sha-<short>"
git push origin main
# 5) Argo 自动 sync 后核对
kubectl -n demo rollout status deployment/demo --timeout=180s
curl -s http://127.0.0.1:18080/version   # 经过本地 port-forward 时
```

GitOps 的期望状态永远来自 Git。**不能把 `argocd app rollback` 或
`kubectl rollout undo` 当作 GitOps 回滚**；需要回滚时对 desired state 做
`git revert` 并提交，让 Argo 同步到新 commit。

## 4. 部署前检查（主代理）

Argo CD Helm 安装由主代理完成，本目录不包含安装脚本。满足以下条件后再 apply：

```bash
# 1) Argo CD CRD/controller 已就绪
kubectl -n argocd get pods
# 2) namespace demo 已存在（Application 不创建它）
kubectl get namespace demo
# 3) gitops/demo/values.yaml 已替换真实镜像 tag/digest 和 gitSha
# 4) （可选）ServiceMonitor CRD 已就绪；否则保持 enabled: false
kubectl get crd servicemonitors.monitoring.coreos.com

kubectl apply -f gitops/argocd/project.yaml
kubectl apply -f gitops/argocd/application.yaml
kubectl -n argocd get application demo -o wide
kubectl -n argocd get appproject demo -o yaml
```

Application/AppProject 是 cluster 内对象，apply 动作由主代理实施；本阶段只
准备文件，未实际执行。

## 5. 演练与 auto-sync

`scripts/drills/inject.sh` 会先检查 Application `demo` 的
`.spec.syncPolicy.automated`。若已启用，必须显式 `--suspend-gitops`，否则拒绝。

- 仅当该参数存在时，脚本才 patch **demo 一个 Application** 去掉 automated；
- 原值写入 `scripts/drills/.state/*.json`（本地，已 gitignore）；
- `recover.sh` 恢复 Deployment env 后，再把原 automated policy 恢复并校验；
- 若恢复流程异常退出，trap 会尝试恢复；如仍失败需立即人工重跑 recover。

细节见 `docs/drills.md`。**不要把暂停 auto-sync 的文件提交到 Git**；
`scripts/drills/.gitignore` 已忽略 `.state/`、`logs/` 与 JSONL。

## 6. 尚未验证 / 待主代理验收

- Argo CD 未安装，Application/AppProject 未 apply，未验证 sync/health。
- `targetRevision: main` 的 Argo 拉取、`../../gitops/demo/values.yaml` 的
  valueFiles 解析需在真实 Argo 上验收；若 Argo 版本不接受该相对路径，改用
  multi-source 的 `$values` ref（当前按用户给定路径实现）。
- GitHub Actions 尚未实际运行；action SHA 已通过 API 核实，Helm 校验和来自官方
  release body，但本地未安装 helm/无法执行 `helm lint`。
- Dockerfile 缺 `ARG APP_VERSION/GIT_SHA`，构建参数固化未完成（见第 1 节）。
- 镜像尚未构建/发布；GitOps 占位未替换前不可部署。
- GHCR 包可见性与集群 imagePullSecret 权限需主代理确认。
