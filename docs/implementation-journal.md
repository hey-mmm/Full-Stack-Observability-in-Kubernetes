# 实施记录（持续更新，非最终验收报告）

日期：2026-11-11，用户时区 Asia/Shanghai。以下只记录已实际执行的事项。

## 仓库

初始提交 `4bc824278dda1e90cc5174ad983676682b2349d6` 已由用户推送。主代理通过 `git ls-remote origin refs/heads/main` 与本地 `git rev-parse HEAD` 对比，二者一致。初始提交只有集群底座和示例服务；后续配置应以之后的提交为准。

## 虚拟机准备

1. 初查：两台均为 Ubuntu 22.04.5、2 vCPU、4 GB 内存、20 GB 虚拟磁盘；根逻辑卷约 10 GB，仅余约 2.2 GB。旧 kubeadm 为 1.28.15，配置指向无法连接的旧 API `192.168.30.130:6443`。
2. 用户明确授权不保留旧集群、直接清理，并要求 Kubernetes 使用最新稳定版。实施时官方 `https://dl.k8s.io/release/stable.txt` 实际返回 `v1.37.2`；固定该版本，不在以后每次运行时自动升级。
3. 用户通过 VMware 将 master 扩展至 2 vCPU/4 GB/50 GB，worker 扩展至 4 vCPU/12 GB/100 GB；主代理通过 guest `nproc`、`free -m`、`lsblk` 复核。
4. 使用 `growpart /dev/sda 3`、`pvresize /dev/sda3`、`lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv` 扩展分区、物理卷、逻辑卷和 ext4。分区表备份在各 guest `/var/backups/observability-lab/`。master 根卷约 48.2 GiB，worker 根卷约 98.2 GiB；扩展后分别可用约 39 GiB、86 GiB。
5. 原清华 Ubuntu apt 源返回 HTTP 403；原 `/etc/apt/sources.list` 还启用了 `file:///cdrom`。保留原配置后禁用安装光盘源，将 Ubuntu 源设为官方 archive/security，启用 main/universe。仍验证 apt 的签名和包哈希，没有关闭签名校验。旧 Docker/Kubernetes 镜像源移出启用配置，后续交由 Ansible 建立固定版本源。
6. VMware vmnet8 为 `11.0.1.0/24`，网关/DNS `11.0.1.2`，DHCP 地址池 `.128–.254`。对 `.10`/`.11` 做 ARP 冲突检查，均无响应；用 Netplan 设 master `11.0.1.10/24`、worker `11.0.1.11/24`。禁用 cloud-init 对网络文件的重新生成；SSH 重连和 `ip route` 已证明静态地址生效。
7. 在两 guest 执行 `kubeadm reset --force`，清理旧 Kubernetes/CNI/etcd 配置；worker 更名为 `worker`。reset 曾报告旧 CNI sandbox 停止超时，因此进一步确认没有 containerd tasks 后停止运行时，将旧 `/var/lib/containerd` 移至 `/var/lib/containerd.legacy-20261111`，重新建立空目录并启动；之后 CRI sandbox 查询为空。Docker 禁用，集群使用 containerd。

## SSH 与控制端

项目通过专用 SSH 密钥连接，不把密码或私钥提交。部署时为 `myt` 临时建立 `/etc/sudoers.d/90-observability-lab`，用 `visudo -cf` 验证；完成实施后移除临时规则，日后复跑使用 `ansible-playbook --ask-become-pass` 或用户自行管理的授权方式。

master 上使用独立控制端 Python，不替换 Ubuntu 的 `/usr/bin/python3`。固定 uv 0.13.7、Python 3.12.9、ansible-core 2.21.6；其安装、语法检查、首次部署和幂等复跑的结果在完成后追加。

## 已有验证

- 主代理在宿主机运行 `python -m unittest discover -s app/tests -v`，8 项全部通过；这是源码接口测试，不能替代容器与集群验收。
- Ansible 基础 YAML 文件可解析；模块语法与实际执行结果待控制端安装完成后检查。
- containerd 插件实际输出将 TYPE 和 ID 分列；已修复检查条件，要求 `io.containerd.cri.v1` 的 `images` 和 `runtime` 均为 `ok`，避免错误拼接插件名称导致假失败。

## 仍待完成

两节点 Ready 与 DNS/跨节点/Service 验收、幂等复跑、示例镜像与部署、监控告警、日志与持久化、故障演练、GitHub Actions、GHCR、ArgoCD 发布与 Git 回退均需实际运行证据。配置文件存在不等于这些项目已通过。
