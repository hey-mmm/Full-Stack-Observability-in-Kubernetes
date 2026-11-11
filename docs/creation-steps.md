# 从虚拟机到可观测性与 GitOps：创建步骤

本文件说明项目做了什么，以及重新创建时的操作顺序。实施状态以 README 和 `docs/evidence/` 为准；步骤说明本身不是验收证据。

## 1. 准备两台虚拟机

使用 VMware Workstation、Ubuntu 22.04.5、NAT 网络。当前实验室配置如下。

| 节点 | 资源 | 地址 | 工作负载 |
| --- | --- | --- | --- |
| master | 2 vCPU / 4 GiB / 50 GB | 11.0.1.10/24 | 控制面、Ansible；节点采集器 |
| worker | 4 vCPU / 12 GiB / 100 GB | 11.0.1.11/24 | 应用、监控、日志、Argo CD |

NAT 网关与 DNS 为 `11.0.1.2`。VM 文件在 `G:\Blog\`。固定地址位于本机 DHCP 池之外；其他宿主机重建时先核对 VMware 网络编辑器，不能照搬网关。Netplan 配置采用 `ens33`、`dhcp4: false`、对应节点地址、默认路由和上述 DNS。通过 VM 控制台使用 `sudo netplan try` 验证后应用。

虚拟磁盘扩容后，须在客体用 `lsblk` 核对分区及 LVM，再扩展分区、PV、LV、文件系统；仅在 VMware 增大磁盘不会扩大 Ubuntu 根目录。本次两台是 `/dev/sda3` 和 `/dev/ubuntu-vg/ubuntu-lv`，实际执行了 `growpart`、`pvresize`、`lvextend -r`。这些设备名不能盲用于其他机器。

旧集群的清理由用户单独授权执行，**日常 playbook 不执行 reset**。重新运行 Ansible 不应删除 etcd 或重新初始化控制面。

## 2. 获取源码和配置控制端

在 master 执行，先安装 `git`、`python3-venv`、`curl`、CA 证书。代码和 SSH 用户均为 `myt`；密码、私钥、kubeconfig 不进入 Git。

```bash
git clone https://github.com/hey-mmm/Full-Stack-Observability-in-Kubernetes.git
cd Full-Stack-Observability-in-Kubernetes
python3 -m venv "$HOME/.venvs/bootstrap"
"$HOME/.venvs/bootstrap/bin/pip" install uv==0.13.7
UV_BIN="$HOME/.venvs/bootstrap/bin/uv"
"$UV_BIN" python install 3.12.9
"$UV_BIN" venv "$HOME/.venvs/ansible" --python 3.12.9
"$UV_BIN" pip install --python "$HOME/.venvs/ansible/bin/python" \
  -r ansible/requirements.txt kubernetes==33.1.0 jsonpatch==1.33 PyYAML==6.0.3
export PATH="$HOME/.venvs/ansible/bin:$PATH"
ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections
```

单独安装 Python 3.12，不覆盖 Ubuntu 的系统 Python。配置 master 到两节点的专用 SSH 公钥认证，并核对、保存 SSH 主机指纹。检查 `ansible/inventory/lab.yml` 的地址和 `ansible/group_vars/all.yml` 的版本与网络参数。使用 sudo 密码时，以下 playbook 命令加 `--ask-become-pass`；不要把 sudo 密码写入 inventory。

本环境下载通过宿主机代理 `http://11.0.1.1:7890`。代理需允许 VM 连接，节点、Pod、Service 网段加入 NO_PROXY。直连环境把 inventory 的 `lab_containerd_http_proxy` 设为空。代理与镜像校验细节见 [network-proxy.md](network-proxy.md)。bootstrap 的 pip/uv/Galaxy 下载也需可用的出网连接，可按网络环境设置 HTTP_PROXY/HTTPS_PROXY/NO_PROXY。

## 3. 用 Ansible 建立集群

先在两节点运行 `scripts/preflight.sh`，核对网络、磁盘、DNS 和旧集群残留。然后在 master 的仓库中执行：

```bash
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/site.yml --syntax-check
ansible-playbook -i inventory/lab.yml playbooks/site.yml --ask-become-pass
# 再执行一次，检查确实没有无意义的 changed。
ansible-playbook -i inventory/lab.yml playbooks/site.yml --ask-become-pass
cd ..
sudo -E bash scripts/acceptance/cluster.sh
```

Ansible 设置主机名、时间、swap、内核、containerd、Kubernetes 软件源及版本；受保护地初始化 master、加入 worker、部署 Calico。master 保留 NoSchedule taint，普通应用只落在 worker。验收验证两节点、DNS、跨节点通信和 Service HTTP，不能仅观察 `kubectl get nodes`。

## 4. 构建和运行示例服务

`app/` 是无数据库的 Python Web 服务。`/healthz`、`/readyz` 用于探针；`/work` 承载测试请求；`/metrics` 暴露请求数和延迟直方图；`/version` 返回构建版本及 Git SHA。日志使用 JSON 和请求 ID，健康探针不计入业务 SLI。

每次推送 main，Actions 执行 8 项单元测试、Helm 检查、Shell 语法检查，然后构建并发布 `ghcr.io/hey-mmm/observability-demo:sha-<完整提交SHA>`。确认 Actions 成功后，更新 `gitops/demo/values.yaml` 的 image.tag、gitSha、appVersion，并提交。三者应对应同一次构建。

首次尚未接管 GitOps 时：

```bash
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/demo.yml --ask-become-pass
cd ..
NAMESPACE=demo bash scripts/acceptance/app.sh
# 在另一个终端持续发请求；错误演练需加 --allow-errors。
bash scripts/traffic.sh --base-url http://<demo-Service-ClusterIP>:8080 \
  --rate 3 --duration 1800 --allow-errors
```

demo playbook 自动检查 ServiceMonitor CRD：阶段 2 暂不创建 ServiceMonitor，安装指标栈后重新执行 demo playbook 即启用应用采集。Argo CD 接管后，demo playbook 会拒绝直接发布，后续只改 Git。

## 5. 分阶段部署存储、指标、日志

```bash
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/platform.yml --tags storage --ask-become-pass
cd ..
sudo -E bash scripts/acceptance/observability.sh --phase storage
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/platform.yml --tags metrics --ask-become-pass
ansible-playbook -i inventory/lab.yml playbooks/demo.yml --ask-become-pass
cd ..
# 完成下一节的真实 500 故障/恢复后，才做最终指标验收。
sudo -E bash scripts/acceptance/observability.sh --phase metrics
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/platform.yml --tags logging --ask-become-pass
cd ..
sudo -E bash scripts/acceptance/observability.sh --phase logging
```

local-path 提供本地 PVC。Prometheus 收集两节点主机、Kubernetes 对象、kubelet、API、DNS、应用指标；Grafana 展示仪表盘；Alertmanager 将触发和恢复事件发送给本地 JSON webhook receiver，receiver 将事件持久化。它验证本地通知链路，不代表已配置短信或邮件。

kubeadm 默认只在 loopback 暴露 etcd、scheduler、controller-manager、kube-proxy 指标，本配置不创建这些不可达的采集目标；控制面进程状态仍可从 Pod 指标和事件观察。第一版不扩展这些组件的监听接口。

Alloy 作为 DaemonSet 覆盖两节点，只读挂载容器日志并写入 Loki；request_id 保留在日志内容中，不作为高基数标签。Prometheus 为 7 天/8 GB 上限，Loki 为 72 小时且开启 compactor 清理。local-path 不对本地目录施加硬配额，仍需监控磁盘；上限和 PVC 请求量也不等于实际已经存满这些数据。

## 6. 故障演练和持久化验证

只对 `demo` 应用注入故障。先保持正常流量，然后分别运行：

```bash
bash scripts/drills/inject.sh --fault error --alert-wait 150
bash scripts/drills/record.sh --drill-id <输出的ID> \
  --evidence '<实际指标、日志和事件>' --command '<实际查询命令>' --confirmed
bash scripts/drills/recover.sh --drill-id <输出的ID>
# 恢复并确认告警解除后，再演练 latency 和 startup-failure。
```

可用 `DEMO_BASE_URL=http://<Service-ClusterIP>:8080` 避免滚动发布中端口转发更换 Pod。配置 `ALERT_RECEIVER_URL` 后脚本查询实际 webhook 记录；不能把未配置查询、历史告警或空结果写成已经告警。接入 Argo CD 后，故障注入需显式加 `--suspend-gitops`，恢复脚本还原原来的自动同步策略。

保存故障开始、告警收到、根因确认、服务恢复四个时间；恢复通知另记录。启动失败使用 maxUnavailable=0，预期新 Pod 失败而旧 Pod 继续服务，这验证发布保护。Prometheus/Loki 持久化演练先保存带原时间戳的查询结果，再删除对应 Pod，等待同一 PVC 恢复挂载，查询**重建前**的样本或日志。只检查新 Pod Running 不能证明数据保留。

## 7. 接管 GitOps，验证发布和 Git 回退

```bash
cd ansible
ansible-playbook -i inventory/lab.yml playbooks/gitops.yml --tags argocd --ask-become-pass
ansible-playbook -i inventory/lab.yml playbooks/gitops.yml --tags application --ask-become-pass
```

Argo CD 非 HA 部署。AppProject 只允许本仓库向 demo 命名空间发布指定资源，基础组件由 Ansible 管理。确认 Application 的 Synced、Healthy 和 `/version` 一致，再在 Git 中更新到另一个已成功构建的 SHA，验证新版本；最后 `git revert <修改镜像的提交>` 并 push，等待 Argo 同步、验证旧版本恢复。`kubectl rollout undo` 不能替代 GitOps 回退证据。

具体命令及权限见 [argocd-setup.md](argocd-setup.md)。

## 8. 访问和日常运行

在 Windows 终端运行下列命令，可同时建立 SSH 隧道及 guest 内的端口转发：

```powershell
ssh -L 3000:127.0.0.1:3000 myt@11.0.1.10 "kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
```

浏览器访问 `http://127.0.0.1:3000`。同理转发 Prometheus 9090 或 Argo CD HTTPS 8443:443；不需要 NodePort/Ingress。Grafana 管理密码保存在 monitoring/grafana-admin Secret，Argo 初始密码在 argocd/argocd-initial-admin-secret；仅在自己的终端读取，不提交或截入公开证据。

完成实施后移除临时 sudo 规则，恢复 apt 自动更新定时器，检查故障环境变量、Argo 自动同步和 Pod 重启状态。停止临时流量和端口转发后，再次演示时需主动开启它们。

该平台证明实验室的自动部署、观测、定位、恢复和 Git 发布流程。本地 PVC 不抵御 worker 磁盘损坏；单 worker 不提供业务高可用；7 天 SLO 是练习目标，只有实际积累满窗口并统计停机记录后才能评价达标情况。尚未包含分布式链路追踪。
