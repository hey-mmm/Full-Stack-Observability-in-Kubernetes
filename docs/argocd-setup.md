# Argo CD 安装与单应用 GitOps 准备（阶段 6）

本文描述实际部署使用的 Ansible 配置。2026-11-12 已验证 Application 发布和 Git 回退，详见 [gitops-acceptance.md](gitops-acceptance.md)。
基础组件继续由 Ansible 管理；Argo CD 只注册示例应用 `demo`，不接管平台组件。

## 1. 固定版本与来源

版本在本机缓存的官方 `argo-helm/index.yaml` 与下载后的 `Chart.yaml` 中核实，核实时间为
2026-11-11，未使用 `latest`：

| 项目 | 固定值 |
| --- | --- |
| 官方索引 | <https://argoproj.github.io/argo-helm/index.yaml> |
| chart | `argo-cd` **10.17.2**（稳定版，无 prerelease 后缀） |
| chart appVersion | **v3.6.1** |
| chart tgz | <https://github.com/argoproj/argo-helm/releases/download/argo-cd-10.17.2/argo-cd-10.17.2.tgz> |
| chart sha256 | `c516b221a2380074bd2a3ed04ff6830a19fb07c3719070aa456ed02778767c4f` |
| 本地缓存（仓库外） | `../../work/argocd-cache/argo-cd-10.17.2.tgz` |
| Argo CD 主镜像 | `quay.io/argoproj/argocd:v3.6.1` |
| Redis 镜像 | `docker.io/library/redis:8.6.4-alpine` |

Ansible 安装时使用同一版本和同一个 sha256；`get_url` 超时 120 秒，Helm 等待上限
10 分钟，外层 `timeout` 为 660 秒，避免网络或集群异常导致无限等待。**不使用 Helm 仓库
索引的浮动最新版。**

### 本地 Helm 静态验证记录（2026-11-11）

使用仓库外缓存的 chart 与固定 values 实际执行：

```text
helm lint <chart> -f ansible/roles/argocd/files/values.yaml
  -> 1 chart(s) linted, 0 chart(s) failed

helm template argocd <chart> -n argocd -f ansible/roles/argocd/files/values.yaml
  -> exit 0
```

渲染结果确认：

- 镜像只有 `quay.io/argoproj/argocd:v3.6.1` 与
  `docker.io/library/redis:8.6.4-alpine`；
- `argocd-application-controller`、`argocd-repo-server`、`argocd-server`、
  `argocd-redis` 的 replicas 均为 1；
- `argocd-applicationset-controller` 的 replicas 为 0；
- `argocd-server` Service 为 `ClusterIP`；
- Dex/Notifications 没有渲染出工作负载。

完整渲染文件保存在仓库外：
`../../work/argocd-cache/argocd-rendered.yaml`。该验证只证明 chart 可渲染，
静态渲染只验证配置；真实集群结果另外记录于 `evidence/gitops-*.json`。

## 2. 文件与标签

新增文件：

- `ansible/playbooks/gitops.yml`
- `ansible/roles/argocd/defaults/main.yml`
- `ansible/roles/argocd/tasks/main.yml`
- `ansible/roles/argocd/files/values.yaml`
- `docs/argocd-setup.md`

执行方式：

```bash
cd /path/to/repo/ansible

# 只安装/升级 Argo CD。即使 demo 镜像仍是占位，也不会被阻塞。
ansible-playbook playbooks/gitops.yml --tags argocd

# 安装 Argo CD 后，单独注册/更新 demo 的 AppProject 与 Application。
# image.tag / gitSha 必须已经是真实的 40 位 SHA，否则明确失败。
ansible-playbook playbooks/gitops.yml --tags application
```

Playbook 使用 inventory 中的 `kube_control_plane`，`become: true`，并固定：

```yaml
ansible_python_interpreter: /home/myt/.venvs/ansible/bin/python
```

因此 `kubernetes.core.k8s` / `k8s_info` 使用控制端 venv 中的 Kubernetes SDK，而不是系统
Python 3.10。角色顺序是已有的 `helm` role（固定 3.22.1，先执行）→ 新增 `argocd` role。
两个标签互不替代：`--tags argocd` 不检查 demo 镜像；`--tags application` 不重装 Argo CD。

## 3. 安装形态与资源预算

非 HA，开启单节点 Redis，Dex/Notifications 关闭：

| 组件 | replicas | requests | limits |
| --- | ---: | --- | --- |
| application-controller | 1 | 100m / 256Mi | 500m / 768Mi |
| repo-server | 1 | 100m / 256Mi | 500m / 768Mi |
| server | 1 | 100m / 256Mi | 500m / 512Mi |
| redis | 1 | 50m / 64Mi | 200m / 128Mi |
| **合计** | **4** | **350m / 832Mi** | **1700m / 2176Mi** |

worker 规划为 12GiB；上述 limits 合计约 2.1GiB，为已有监控/日志/demo 负载留出余量。
实际部署前仍应在真实 worker 上按当前 `kubectl describe node` 核算。

访问方式：

- `server.service.type: ClusterIP`；
- `server.ingress.enabled: false`；
- 不创建 NodePort、Ingress、HTTPRoute、GRPCRoute 或 ListenerSet；
- 只通过 `kubectl port-forward` 临时访问。

## 4. TLS 与管理员密码

保留 chart 默认的 TLS：`configs.params."server.insecure": false`，不添加
`--insecure`。chart 会生成自签名证书，浏览器首次访问出现证书警告属于预期；**不要为了
消除警告而关闭 TLS**。

Ansible **不会读取、打印或记录初始管理员密码**。需要时在用户自己的本地终端执行：

```bash
# 仅输出到用户本地终端；不要把输出粘贴到 Ansible 日志、CI 或 Git。
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

用户名是 `admin`。登录后应修改密码，并按需删除初始 Secret。端口转发：

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# 浏览器访问 https://127.0.0.1:8080
# 命令行自签名证书场景可使用 curl -k https://127.0.0.1:8080
```

## 5. demo namespace、AppProject 与 Application

`--tags application` 的顺序是：

1. 由 Ansible 创建 `demo` Namespace（Application 不创建 Namespace）；
2. apply `gitops/argocd/project.yaml`；
3. 从 API 读回 AppProject 并断言：只允许本仓库、只允许 `demo` namespace、
   `clusterResourceWhitelist` 为空、namespace 资源白名单没有 `*`；
4. 读取 `gitops/demo/values.yaml`，要求 `image.tag` 为 `sha-<40位小写hex>` 且
   `gitSha` 为 40 位小写 hex；
5. 只有第 4 步通过，才 apply `gitops/argocd/application.yaml`。

如果镜像仍是占位（例如 `sha-REPLACE_WITH_ACTUAL_IMMUTABLE_TAG`），任务会**明确失败并拒绝
创建 Application**，不会用占位镜像制造“已同步”的假象。安装 Argo CD 本身不受影响：
先运行 `--tags argocd`，等维护者把已构建成功的真实 SHA 写入 `gitops/demo/values.yaml` 并提交后，
再运行 `--tags application`。

AppProject 的边界（以仓库现有文件为准）：

- `sourceRepos` 只有本仓库 HTTPS URL，没有 `*`；
- `destinations` 只有 `https://kubernetes.default.svc` 的 `demo` namespace；
- `clusterResourceWhitelist: []`，不能创建 Namespace、CRD、ClusterRole 等；
- `namespaceResourceWhitelist` 只允许 Deployment、Service、ServiceMonitor；
- Application 不设置 `CreateNamespace`，`demo` 必须预先存在。

## 6. 上游 chart 对 ApplicationSet 的限制

`argo-cd` chart 从 6.9.0 起**无条件渲染 ApplicationSet controller**，10.17.2 也没有
`applicationSet.enabled` 开关。因此本实现使用官方支持的 `applicationSet.replicas: 0`：
ApplicationSet **Pod 数量为 0**，不会参与单应用 GitOps；但 chart 仍会创建其 Deployment
对象和 `applicationsets.argoproj.io` CRD。这一点不能声称成“manifest 完全不存在”。
若必须连 Deployment/CRD 都删除，需要额外的 post-renderer 或集群侧裁剪，本阶段未实现。

Dex 与 Notifications 则有正式的 `enabled: false`，不会创建对应工作负载。

## 7. 安装后检查

```bash
kubectl -n argocd get pods
kubectl -n argocd get deploy,statefulset,svc
kubectl -n argocd get deploy argocd-applicationset-controller -o jsonpath='{.spec.replicas}'
# 期望输出 0

kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.type}'
# 期望输出 ClusterIP

kubectl -n argocd get ingress
# 期望 No resources found
```

`--tags application` 成功后：

```bash
kubectl get namespace demo
kubectl -n argocd get appproject demo -o yaml
kubectl -n argocd get application demo -o wide
```

## 8. 实际验收与边界

- 4 个核心 Pod Ready，Application Synced/Healthy。
- Git 发布和 `git revert` 回退后，`/version` 与实际镜像 SHA 均匹配，健康/就绪/业务接口返回 200。
- 安装配置复跑 master 30 个任务、changed=0，见 `evidence/argocd-idempotency.txt`。
- repo-server 使用 `http://11.0.1.1:7890` 代理出网，需宿主机代理保持可用；直连环境要将 values 中 repoServer.env 改为空列表。
- 本次验收覆盖 API、实际服务与权限配置；未将浏览器管理员登录作为验收项。
- 非 HA，ApplicationSet 为 replicas=0，上游限制见第 6 节。
