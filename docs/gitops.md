# CI 与 GitOps 交付说明

本文件说明本仓库可复现的 CI、镜像发布、Argo CD 安装和 GitOps 回退路径。仓库为
`https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes`。

边界先说清楚：

- 基础平台（Kubernetes、Calico、local-path、监控、日志、CRD 等）继续由
  Ansible/Helm 管理；
- Argo CD 只管理 `demo` 一个应用，不接管平台组件；
- Git 是 `demo` 的唯一期望状态来源，镜像发布和回退都通过 Git 提交完成；
- Argo CD Pod 健康只证明控制面可用，应用是否真正同步、镜像和 HTTP 是否一致，
  仍要以 Application 状态和验收脚本为准；
- 回退验收的最终结论以 [docs/gitops-acceptance.md](gitops-acceptance.md) 为准，
  本文件只记录发布与回退过程，不代替该报告的结论。

## 1. 已验证状态

| 项目 | 已验证事实 |
| --- | --- |
| CI | [Actions run 43031692016](https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes/actions/runs/43031692016) 对提交 `10462f1a5cedaf8466fd1dc85f8c788eb4059496` 成功，测试、构建和 GHCR 推送均通过。 |
| Argo CD | chart `10.17.2`，Argo CD `v3.6.1`；application-controller、repo-server、server、redis 四个核心 Pod 健康。 |
| Baseline | Application `demo` 在 Git revision `10462f1a5cedaf8466fd1dc85f8c788eb4059496` 为 `Synced/Healthy`，实际镜像为 `ghcr.io/hey-mmm/observability-demo:sha-c0bff8abf5625903e5b9b19b586e9660b9fe7a8c`。 |
| 发布 | 提交 `9b4f6884d4f2fdceb32df8b08005a93d18952b24` 只修改 values，将期望镜像切到 `sha-10462f1a5cedaf8466fd1dc85f8c788eb4059496`；`/version` 和 HTTP 检查实测通过。 |
| 回退 | 提交 `60d5deae28eacc452535ed1b36db243fa2bb9505` 是对 `9b4f6884d4f2fdceb32df8b08005a93d18952b24` 的 `git revert`，已 push；回退验收的最终结论见 [docs/gitops-acceptance.md](gitops-acceptance.md)。 |
| 当前 values | 已回到镜像 `sha-c0bff8abf5625903e5b9b19b586e9660b9fe7a8c`，与回退提交一致。 |

注意区分两个 SHA：

- **Git revision** 是 Argo 同步的仓库提交，例如 baseline 的
  `10462f1a5cedaf8466fd1dc85f8c788eb4059496`；
- **镜像 SHA** 是 values 指向的 CI 构建提交，例如 baseline 实际运行的
  `c0bff8abf5625903e5b9b19b586e9660b9fe7a8c`。

Baseline 的 Git revision 是 `10462f1...`，但该 revision 的 values 仍指向 c0
镜像；发布提交 `9b4f688...` 才把镜像切到 `10462f1...` 构建的镜像。二者不是同一个
概念，不能把 `sha-10462f1...` 误认为 baseline 已经在运行的镜像。

## 2. CI：测试、构建与 GHCR

workflow 文件：`.github/workflows/ci.yml`；可复用 Helm 安装 action：
`.github/workflows/actions/setup-helm/action.yml`。

### 触发与权限

- PR：只运行测试、Helm lint/template 和 Shell 语法检查，不登录 GHCR、不构建、不推送。
- push `main`：`test` 通过后，`build` 才登录 GHCR、构建并推送镜像。
- `permissions` 最小化：workflow 顶层只有 `contents: read`；只有 push `main`
  的 `build` job 额外申请 `packages: write`。
- 镜像：`ghcr.io/hey-mmm/observability-demo`。
- tag：`sha-${GITHUB_SHA}`，即完整 40 位 commit；**不生成 `latest`**。
- 构建成功后把 image tag、digest、`APP_VERSION`、`GIT_SHA` 写入 GitHub Step Summary。
- workflow 不会修改 `gitops/demo/values.yaml`，不会自动 `git push`，避免 CI 提交
  触发自身循环。镜像发布后的 Git 更新由人完成。

### 测试内容

`test` job 使用 Python 3.13.9，执行：

```bash
python -m unittest discover -s app/tests -v
helm lint charts/demo
helm lint charts/demo -f gitops/demo/values.yaml
helm template demo charts/demo -n demo -f gitops/demo/values.yaml
```

另外会渲染启用 ServiceMonitor 的版本，并回归检查渲染结果中不存在
`nodePort`、`hostPath`、`Ingress` 或 `latest`；Shell 脚本逐个执行 `bash -n`。

### Dockerfile 构建参数契约

`app/Dockerfile` 已声明并固化构建参数：

```dockerfile
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ENV APP_VERSION=${APP_VERSION} GIT_SHA=${GIT_SHA}
```

CI 在登录 GHCR 前检查这两个 `ARG` 是否存在；缺失时直接失败，不会推送一个忽略
版本元数据的镜像。当前 Dockerfile 已满足契约，**过去“Dockerfile 缺 ARG 导致
CI 不产镜像”的阻塞已不存在**；实际成功 run 和 GHCR 镜像即为证据。

workflow 传入：

```text
--build-arg APP_VERSION=0.1.0-${GITHUB_SHA}
--build-arg GIT_SHA=${GITHUB_SHA}
```

并写入 `org.opencontainers.image.source/revision/version` labels。运行时 Helm 还会
注入 `APP_VERSION`、`GIT_SHA` 环境变量，供 `/version` 和 `/work` 返回。

### 固定版本

| 组件 | 固定值 |
| --- | --- |
| `actions/checkout` | `v7.0.1`，commit `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/setup-python` | `v7.1.0`，commit `6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` |
| Helm | `v3.22.1`，linux-amd64 SHA256 `896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea` |
| Argo CD chart | `10.17.2`，app `v3.6.1` |

Helm 由仓库内 composite action 下载固定 URL，先执行 `sha256sum --check --strict`，
通过后才安装到 `/usr/local/bin/helm`；不下载 `latest`，不依赖未固定的第三方
setup action。

## 3. Argo CD 安装、幂等与权限边界

### 安装命令

Argo CD 由 Ansible 安装，不是手工 `kubectl apply` 一大套上游清单。控制端需已按
`ansible/requirements.txt` 和 `ansible/requirements.yml` 安装固定依赖，并可通过
`ansible/inventory/lab.yml` SSH 到两节点；playbook 使用 master 上的 kubeconfig，
且当前固定控制端 Python 为 `/home/myt/.venvs/ansible/bin/python`，在其它控制端
复现时需同步调整。

控制端进入 `ansible/` 后执行：

```bash
cd ansible

# 只安装/升级 Argo CD；不要求 demo values 已经是最终镜像
ansible-playbook playbooks/gitops.yml --tags argocd

# 安装后，创建 demo namespace、AppProject，校验 values，再注册 Application
ansible-playbook playbooks/gitops.yml --tags application
```

首次完整安装也可以一次执行：

```bash
ansible-playbook playbooks/gitops.yml --tags argocd,application
```

`--tags argocd` 只管理 Argo CD 的 Helm release；`--tags application` 才创建
`demo` namespace、应用 `gitops/argocd/project.yaml`、检查
`gitops/demo/values.yaml` 并创建 `gitops/argocd/application.yaml`。如果只装 Argo
CD，先执行前者即可。

### 安装前置检查

`gitops.yml` 的 preflight 块带 `always` tag，两种模式都会执行，并硬性要求：

- 集群恰好 2 个节点，且全部 `Ready`；
- kubelet 和 Kubernetes server 均为固定版本 `v1.37.2`；
- API `/readyz` 正常；
- Helm 为 `v3.22.1`（由已有 `helm` role 先安装/校验）。

因此该 playbook 面向本仓库的 1 master + 1 worker 实验环境；节点数、版本或 Helm
不匹配时会拒绝继续，而不是尝试升级或重建集群。

### 幂等边界

- `--tags argocd` 在 Helm 升级前读取现有 release 的 metadata 和 values；只有
  chart 版本不是 `10.17.2`、release 状态不是 `deployed`，或 values 与
  `ansible/roles/argocd/files/values.yaml` 不一致时才执行 Helm upgrade。
  相同输入重复执行会跳过 upgrade，不会主动重启 Argo CD Pod。
- 目录、values 文件、chart 下载和 Kubernetes 对象 apply 都是声明式的；对象已
  存在且内容一致时不会产生新的变更。
- `--tags application` 会重复校验 AppProject 的仓库、目标 namespace、cluster
  resource 白名单，以及本地 values 的 `image.repository`、40 位 `image.tag`、
  40 位 `gitSha`。不满足时在创建/更新 Application 前失败。
- `--tags application` **不会** `git commit`、`git push`，也不会等待 Argo 完成
  同步或 Healthy。它验证的是本地 values；Application 实际读取远端 `main`，
  所以本地改了 values 但没 push 时，Argo 仍按远端旧提交同步。
- playbook 不替代 Argo 的持续调谐，不修复 `demo` 之外的资源，也不管理平台组件；
  它不会强制触发一次 sync，不会清理 Application operation 历史，也不会把
  “apply 成功”当成“应用已 Synced/Healthy”。
- Helm 的幂等比较针对 chart 版本和用户 values，不是渲染后清单或运行中 Pod 的
  逐字段 diff；相同 values 重跑不会触发 rollout。

### Application 与 AppProject

关键对象来自：

- `gitops/argocd/project.yaml`
- `gitops/argocd/application.yaml`
- `gitops/demo/values.yaml`

Application `demo`（namespace `argocd`）的实际配置：

- AppProject：`demo`；
- `source.repoURL`：本仓库 HTTPS URL；
- `source.targetRevision: main`；
- `source.path: charts/demo`；
- `source.helm.valueFiles: ../../gitops/demo/values.yaml`，相对 chart 路径解析到
  仓库根的 values 文件；该路径已在真实 Argo 同步中生效；
- destination：`https://kubernetes.default.svc` / namespace `demo`；
- `syncPolicy.automated`：`prune: true`、`selfHeal: true`；
- 不设置 `CreateNamespace`。`demo` namespace 由 playbook 在 Application 之前创建。

AppProject 的限制：

- `sourceRepos` 只允许本仓库；
- destination 只允许 `https://kubernetes.default.svc` 的 `demo` namespace；
- `clusterResourceWhitelist: []`，禁止 Namespace、CRD、ClusterRole 等
  cluster-scoped 资源；
- `namespaceResourceWhitelist` 只放行 `Deployment`、`Service`、`ServiceMonitor`。

因此 Argo 不能借这个 project 部署到其它 namespace，也不能创建集群级资源。
ServiceMonitor 依赖平台已安装的 `monitoring.coreos.com` CRD；该 CRD 和监控组件
由 Ansible/Helm 管理，不由 Argo 创建。

检查四类核心 Pod 和 Application：

```bash
kubectl -n argocd get pods
kubectl -n argocd get application demo -o wide
kubectl -n argocd get appproject demo -o yaml
```

期望 application-controller、repo-server、server、redis 各一个 Ready Pod；
ApplicationSet controller 的 replicas 为 0，Dex 和 notifications 未启用。Pod 健康
之后，仍需看 Application 的 `SYNC STATUS` 和 `HEALTH STATUS`。

## 4. 镜像发布：只改 Git

### 当前 values

当前 `gitops/demo/values.yaml` 已回到 c0 镜像：

```yaml
image:
  repository: ghcr.io/hey-mmm/observability-demo
  tag: "sha-c0bff8abf5625903e5b9b19b586e9660b9fe7a8c"
appVersion: "0.1.0-c0bff8abf5625903e5b9b19b586e9660b9fe7a8c"
gitSha: "c0bff8abf5625903e5b9b19b586e9660b9fe7a8c"
```

现有 chart 只渲染 `image.repository:image.tag`，尚不支持 `image.digest`。因此：

1. tag 必须是不可变的 `sha-<完整40位commit>`；
2. 禁止 `latest`、`main` 或可移动 tag；
3. 每次 CI 构建成功后，以 Step Summary 中的实际 tag 为准更新 values；
4. 如果后续 chart 增加 digest 支持，应优先使用 digest，并保留说明。

### 发布步骤

1. 确认 push `main` 的 Actions run 中 `Test, lint, render` 和
   `Build and push image` 均成功。
2. 从 run 的 Step Summary 取得 `ghcr.io/hey-mmm/observability-demo:sha-<40 hex>`
   和对应构建 commit。
3. 更新 `gitops/demo/values.yaml`：

   ```yaml
   image:
     repository: ghcr.io/hey-mmm/observability-demo
     tag: "sha-<构建 commit 的40位>"
   appVersion: "0.1.0-<构建 commit 的40位>"
   gitSha: "<构建 commit 的40位>"
   ```

4. 只提交 values 并 push：

   ```bash
   git add gitops/demo/values.yaml
   git commit -m "Promote CI image <short-sha> through GitOps"
   git push origin main
   ```

5. 等待 Argo 自动同步，核对 Application 和实际镜像：

   ```bash
   kubectl -n argocd get application demo -o wide
   kubectl -n demo get deployment demo \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl -n demo rollout status deployment/demo --timeout=180s
   ```

6. 在能直达 ClusterIP 的环境（通常是 master）运行验收脚本，或通过
   `kubectl -n demo port-forward svc/demo 18080:8080` 手工检查 `/version`。

CI 不会自动提交 desired state；不要把镜像 tag 直接改到 Deployment，也不要改
`targetRevision` 去指向某个浮动分支。`selfHeal` 会把绕过 Git 的改动同步回 Git
状态。

## 5. 验收脚本

脚本：`scripts/acceptance/gitops.py`。它对集群只读，失败返回非 0，会核对：

- Application `demo` 的 sync revision 等于指定 Git commit，状态为
  `Synced`、`Healthy`；
- Application 使用 project `demo`、本仓库、namespace `demo`，且 auto-sync 的
  `prune`、`selfHeal` 为 true；
- AppProject 没有 cluster-scoped 白名单；
- Deployment 镜像等于 `ghcr.io/hey-mmm/observability-demo:sha-<image-sha>`；
- Service 为 `ClusterIP`；
- `/version` 的 `git_sha` 等于 `--image-sha`，`/healthz`、`/readyz`、`/work`
  返回 200；
- 四个 Argo CD 核心 Pod Ready。

用法：

```bash
python3 scripts/acceptance/gitops.py \
  --git-revision <Application 当前应同步到的40位commit> \
  --image-sha <Deployment 应运行的40位镜像commit> \
  --output <证据文件.json>
```

本次记录对应的参数分别是：

```text
发布验证：--git-revision 9b4f6884d4f2fdceb32df8b08005a93d18952b24
          --image-sha   10462f1a5cedaf8466fd1dc85f8c788eb4059496

回退验证：--git-revision 60d5deae28eacc452535ed1b36db243fa2bb9505
          --image-sha   c0bff8abf5625903e5b9b19b586e9660b9fe7a8c
```

脚本读取实时集群，只有 Application 当前确实处于目标 revision 时才会通过；历史
发布不能靠事后重跑脚本证明，应保留当时的输出。回退验收是否通过，以
[docs/gitops-acceptance.md](gitops-acceptance.md) 的结论为准。

## 6. Git 回退

回退必须改变 Git desired state：

```bash
git revert <要撤销的发布提交>
# 如有冲突，解决后 git add；不要用 kubectl 改回去
git push origin main
```

然后等待 Argo 自动同步到新的 revert commit，再运行上一节的验收脚本。

**不要**用以下方式代替 Git 回退：

- `kubectl rollout undo deployment/demo`；
- `argocd app rollback`；
- 手工把 Deployment 镜像改回旧 tag；
- 修改 Argo Application 的 targetRevision 绕过 `main`。

这些操作只改变集群现状，不改变 Git，下一次 `selfHeal` 仍会同步回 Git 状态，也无法
留下可审计的 desired state 历史。

本次实际回退链：

```text
9b4f6884d4f2fdceb32df8b08005a93d18952b24  Promote CI image 10462f1 through GitOps
60d5deae28eacc452535ed1b36db243fa2bb9505  Revert "Promote CI image 10462f1 through GitOps"
```

`60d5dea...` 已 push，内容是把 values 从 `sha-10462f1...` 恢复到
`sha-c0bff...`。本文件不预判回退验收结果，也不虚构 `/version` 或 Application
的回退状态；最终验收结论见 [docs/gitops-acceptance.md](gitops-acceptance.md)。

## 7. repoServer 代理

本实验通过宿主机代理访问 GitHub 和外部 registry。`argocd-repo-server` 的固定
环境变量在 `ansible/roles/argocd/files/values.yaml`：

```yaml
repoServer:
  env:
    - name: HTTP_PROXY
      value: http://11.0.1.1:7890
    - name: HTTPS_PROXY
      value: http://11.0.1.1:7890
    - name: NO_PROXY
      value: localhost,127.0.0.1,11.0.1.0/24,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local
```

- repo-server 使用该代理出网拉取 Git；`NO_PROXY` 覆盖本机、节点网段、Pod/Service
  网段和集群 DNS 后缀，内部通信不经过代理。
- 本实验的 containerd 也使用同一代理出口；代理关闭时，Argo 拉取 Git 会失败，
  尚未缓存的新镜像也无法下载。已经缓存的镜像和运行中的 Pod 可能继续服务，但新的
  Git revision 无法完成同步。
- 修改代理或 `NO_PROXY` 后，重新执行
  `ansible-playbook playbooks/gitops.yml --tags argocd`，让 Helm release 更新。
- 不要把 `NO_PROXY` 改成 `*` 当作代理故障的绕过手段；这会让 repo-server 对
  GitHub 也直连，而不是修复代理。代理不可用时，先恢复代理，而不是删除
  repoServer 的代理配置。

排查时查看 repo-server 日志：

```bash
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

## 8. 故障演练与 auto-sync

`scripts/drills/inject.sh` 默认拒绝在 Argo auto-sync 开启时直接 patch Deployment：

```bash
scripts/drills/inject.sh --fault error --suspend-gitops
scripts/drills/inject.sh --fault latency --latency-ms 3000 --suspend-gitops
scripts/drills/inject.sh --fault startup-failure --suspend-gitops
```

- 只有显式传入 `--suspend-gitops`，脚本才会把 `argocd/demo` 一个 Application 的
  `automated` 置空，并把原值保存到 `scripts/drills/.state/`（已 gitignore）。
- `recover.sh` 先按 state 恢复 Deployment 的原始 env，等待 rollout 和
  `/healthz`、`/readyz`，再恢复 auto-sync 并校验恢复值。
- 脚本异常退出时 trap 会尝试恢复；如果失败，立即手工执行：

  ```bash
  scripts/drills/recover.sh --state scripts/drills/.state/<drill-id>.json
  ```

- 暂停 auto-sync 只是演练期间的临时操作，不是发布或回退手段；不要提交 state
  文件，也不要把 `--suspend-gitops` 写进 GitOps values。

更多演练细节见 [docs/drills.md](drills.md)。

## 9. 范围与限制

- Argo CD 只管理 `demo` 的 Deployment、Service、ServiceMonitor；不管理
  Namespace、CRD、Ingress、NodePort 或平台组件。
- `demo` namespace 由 Ansible 创建，Argo 不负责创建。
- 平台组件和监控/日志 CRD 由 Ansible/Helm 管理，Argo 同步失败不会触发平台重装。
- 当前是单 worker、local-path 实验环境，不宣称多副本高可用、跨节点迁移或生产级
  备份。
- 镜像只使用不可变 `sha-<40 hex>` tag，不使用 `latest`。
- 回退的最终验收结论只在
  [docs/gitops-acceptance.md](gitops-acceptance.md) 中给出。
