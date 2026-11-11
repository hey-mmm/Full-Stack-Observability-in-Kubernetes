# 阶段 1 运行与验收说明

> 本文件是操作说明，不是执行结果。当前仓库代码尚未在目标 VM 上运行，不能写成“已部署”或“已通过”。旧 1.28 集群由主代理在 playbook 之外清理；本仓库不自动执行 `kubeadm reset`。

## 1. 前置条件

- master `11.0.1.10`，worker `11.0.1.11`，SSH 用户 `myt`。
- 主代理已完成或确认：
  - 旧 1.28 集群已按用户授权清理；
  - master 50 GB、worker 100 GB 磁盘，worker 4 vCPU / 12 GiB 内存；
  - 两台 VM 可互相访问，22 端口可达；
  - `myt` 可免交互 sudo；
  - 时区和 NTP 可调整。
- inventory 只保存地址和用户名，不保存密码。执行环境必须自行提供 SSH 认证。
- 不在 Windows 上运行 Ansible。

## 2. 安装受支持的 Ansible 控制端

Ubuntu 22.04 的 Python 3.10 不能运行当前支持的 ansible-core 组合。master 已提供固定 uv `0.13.7`，不要覆盖系统 Python：

```bash
cd Full-Stack-Observability-in-Kubernetes

UV_BIN=/opt/observability-bootstrap/bin/uv
"$UV_BIN" --version   # 必须为 uv 0.13.7

"$UV_BIN" python install 3.12.9
"$UV_BIN" venv "$HOME/.venvs/ansible" --python 3.12.9
"$UV_BIN" pip install \
  --python "$HOME/.venvs/ansible/bin/python" \
  -r ansible/requirements.txt \
  kubernetes==33.1.0 jsonpatch==1.33 PyYAML==6.0.3
$HOME/.venvs/ansible/bin/ansible-galaxy collection install \
  -r ansible/requirements.yml -p ansible/collections

$HOME/.venvs/ansible/bin/ansible --version
$HOME/.venvs/ansible/bin/ansible-galaxy collection list
```

Python SDK 固定为 `kubernetes 33.1.0`、`jsonpatch 1.33`、`PyYAML 6.0.3`；不修改系统 Python。

固定版本：

- Python `3.12.9`（uv managed）
- ansible-core `2.21.6`（当前支持线；2.22 对应 Ansible 15 尚在开发）
- `ansible.posix 2.2.2`
- `community.general 14.0.1`
- `kubernetes.core 6.6.0`

collection 安装到 `ansible/collections`（已在 `.gitignore` 排除）；`ansible.cfg` 的 `collections_paths = ./collections` 只在 `ansible/` 目录执行时生效。不要用系统 `pip install ansible` 覆盖 Ubuntu 包。

> 若 uv 安装器版本变化，应在实际 bootstrap 记录中注明。

## 3. 只读前置检查

在两台 VM 上分别执行。脚本不会安装软件、修改 sysctl、加入集群或扫描其他地址。worker 上若没有仓库副本，由主代理只复制 `scripts/preflight.sh` 到 worker 执行；脚本不依赖仓库其他文件。

```bash
chmod +x scripts/preflight.sh scripts/acceptance/cluster.sh

# master
./scripts/preflight.sh \
  --role control-plane \
  --expected-ip 11.0.1.10 \
  --peer 11.0.1.11

# worker
./scripts/preflight.sh \
  --role worker \
  --expected-ip 11.0.1.11 \
  --peer 11.0.1.10
```

必须没有 `[FAIL]`。`[WARN]` 需逐项判断；特别是旧 kubeadm 版本、已存在的 `admin.conf`/`kubelet.conf`、端口占用，不能忽略。

## 4. Ansible 连通性与语法检查

以下命令在 master 的仓库根目录执行：

```bash
cd ansible

# 只读连通性检查
$HOME/.venvs/ansible/bin/ansible all -i inventory/lab.yml -m ansible.builtin.ping

# 不执行任务，只做语法与任务枚举
$HOME/.venvs/ansible/bin/ansible-playbook -i inventory/lab.yml playbooks/site.yml --syntax-check
$HOME/.venvs/ansible/bin/ansible-playbook -i inventory/lab.yml playbooks/site.yml --list-tasks
```

说明：

- `ansible.cfg` 的 inventory 是 `inventory/lab.yml`。
- `playbooks/site.yml` 显式 `vars_files: ../group_vars/all.yml`，因为 `ansible/group_vars` 不在当前 playbook 的默认相邻目录中。
- `host_key_checking` 保持开启；不要用关闭 SSH 主机校验来“解决”连接问题。

## 5. 执行阶段 1

确认旧集群已清理后：

```bash
cd ansible
$HOME/.venvs/ansible/bin/ansible-playbook -i inventory/lab.yml playbooks/site.yml
```

执行顺序被拆成五个 play，避免 Calico 控制器在 worker 加入前等待可调度节点而死锁：

1. `common` + `containerd` + `kubernetes`：两台节点。
2. `control_plane`：仅 master，受保护地 init。
3. `calico`：仅 master，只下载、校验、渲染、apply，不等待 rollout。
4. `worker_join`：仅 worker，只 join 并确认 Node 对象注册，不等待 CNI 依赖的 Ready。
5. `verify`：仅 master，等待节点、kube-proxy、Calico、CoreDNS 收敛。

受保护行为：

- `/etc/kubernetes/admin.conf` 存在时，不再 init；先检查 `/readyz`、节点读取和 server 版本。版本不是 `v1.37.2` 或集群不健康立即 fail。
- 若只有 `kube-apiserver.yaml` 而没有 `admin.conf`，判定为部分初始化并 fail，不覆盖。
- worker 有 `kubelet.conf` 时，校验其 API server 是否为 `https://11.0.1.10:6443`，并确认目标集群中的 Node 对象和 InternalIP 匹配；不满足则 fail，不只凭文件存在就认为已加入。
- join 命令和 kubeadm init 输出使用 `no_log`；init 日志仅 root 可读。

## 6. 验收

在 master 上、使用管理 kubeconfig 执行：

```bash
cd Full-Stack-Observability-in-Kubernetes
KUBECONFIG=/etc/kubernetes/admin.conf ./scripts/acceptance/cluster.sh
```

脚本实际检查：

- API `/readyz`。
- 恰好 2 个节点，`master`/`worker` 均 Ready，InternalIP 分别为 `.129`/`.130`，容器运行时为 containerd。
- kubeadm `podSubnet` 与 Calico 默认 IPv4 IPPool 均为 `10.244.0.0/16`。
- kube-apiserver、controller-manager、scheduler、etcd Ready。
- kube-proxy、calico-node、calico-kube-controllers、CoreDNS Ready。
- `kubernetes` Service 为 `10.96.0.1`，`kube-dns` 为 `10.96.0.10`。
- master 的 control-plane taint 仍存在，Calico 有 `Exists` toleration。
- 创建临时 master/worker 测试 Pod（固定 `busybox:1.36.1`，无 latest），验证：
  - 两 Pod 获得不同 Pod IP；
  - 集群 DNS 解析 `kubernetes.default.svc.cluster.local`；
  - master→worker 和 worker→master 双向 ICMP 跨节点 Pod 网络。
- 退出时删除临时命名空间；不删除 taint，不执行 reset。

## 7. 幂等复跑

首次验收通过后再执行一次：

```bash
cd ansible
$HOME/.venvs/ansible/bin/ansible-playbook -i inventory/lab.yml playbooks/site.yml
```

预期：

- 不重新 `kubeadm init`；
- 已存在 `kubelet.conf` 的 worker 不生成新 token、不重新 join；
- Calico 上游文件 checksum 保持 `2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5`，不反复重下载；渲染文件无变化；
- 第二次运行不破坏节点 Ready、CoreDNS 或 Calico。

若复跑产生 init/join 或大范围重建，应视为 bug，停止并保留日志，不要继续下一阶段。

## 8. 常见失败与处理

| 现象 | 处理 |
| --- | --- |
| `admin.conf` 存在但版本为 1.28 或 `/readyz` 失败 | 停止。主代理在 playbook 外清理旧集群；本仓库不会自动 reset。 |
| 只有 `kube-apiserver.yaml`，无 `admin.conf` | 停止。检查部分初始化状态，不要直接删除证书或再次 init。 |
| worker `kubelet.conf` 存在但 API server/Node/IP 不匹配 | 停止。该 enrollment 不属于目标集群，按主代理流程清理后再 join。 |
| containerd 启动失败或 CRI 插件未加载 | 检查 `/etc/containerd/config.toml`（v3）和 `journalctl -u containerd`；不得回退到旧 2.2.3 配置。 |
| Calico Pod 不 Ready | 检查 `kubectl -n kube-system get pods -o wide`、Calico 日志、Pod CIDR 是否为 `10.244.0.0/16`；不要删除 master taint 来代替排查。 |
| 测试镜像拉取失败 | 记录网络/镜像仓库错误；不要改成 `latest` 或跳过跨节点网络检查来宣告通过。 |

## 9. 结果记录要求

阶段 1 验收记录至少包含：

- 实际执行日期、命令、Ansible 版本、Kubernetes/Calico/containerd 版本；
- `kubectl get nodes -o wide` 实际输出；
- 验收脚本退出码和 pass/fail 计数；
- 第二次运行的关键 changed/unchanged 结果；
- 未通过项和未验证项。

未实际执行前，以上全部标记为“待执行”，不得预填成功结论。
