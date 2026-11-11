# 实验室代理与镜像下载

VM 直连部分官方 registry 时出现 TLS EOF，访问官方 manifest/tag 时通过宿主机 FlClash：`http://11.0.1.1:7890`。代理必须允许来自 VMware NAT 网段的连接。

Ansible inventory 的 `lab_containerd_http_proxy` 配置此地址；改为空字符串可关闭代理。`group_vars/all.yml` 将其映射到 containerd role，并为下载/Helm 任务设置相同出口。代理只服务出网下载，不承载 Pod/Service 通信。

`containerd_no_proxy` 包含 localhost、节点网段、Pod/Service CIDR、`.svc`、`.cluster.local` 和 `.nju.edu.cn`。role 管理 systemd drop-in `10-proxy.conf`，设置大小写 HTTP_PROXY/HTTPS_PROXY/NO_PROXY；变更后重新加载 systemd 并重启 containerd。`/etc/crictl.yaml` 显式指向 containerd CRI socket。

## 镜像层加速

```yaml
lab_containerd_registry_mirrors:
  docker.io: https://docker.m.daocloud.io
  quay.io: https://quay.nju.edu.cn
  ghcr.io: https://ghcr.nju.edu.cn
  registry.k8s.io: https://k8s.nju.edu.cn
```

containerd v3 使用 `/etc/containerd/certs.d/<registry>/hosts.toml`。`server` 为官方端点，镜像站仅有 `capabilities = ["pull"]`，不授予 resolve：tag 到 digest 的解析仍由官方完成，镜像内容按 digest 验证，TLS 校验保持开启。网络失败时会尝试官方出口，镜像站可用性并无保证。

role 只支持上面四个 registry。删除映射时仅清理带 role 管理标记的 hosts.toml，不删除用户配置或非空目录。`docker.nju.edu.cn` 在本环境返回 403，因此未启用。

首次部署还在 playbook 外预拉并缓存部分镜像。Kubernetes 七个镜像逐个比对官方与阿里云 linux/amd64 manifest 摘要，Calico 比对官方与 NJU 摘要；证据见 `docs/evidence/*provenance.json`。预拉缓存不替代后续版本固定，也不绕过 TLS 验证。

## DNS 故障与处理

旧节点 resolver 残留 `search localdomain`，Pod 在 `ndots:5` 下先查询 `<Service FQDN>.localdomain`。代理 DNS 对该不存在域名返回 198.18.x.x，导致 nslookup 看似正确但 HTTP 采用假地址。common role 清除该残留并重启 systemd-resolved；已有 Pod 需重建以刷新搜索域。完整排查与 33 项集群验收见 `docs/evidence/stage1-cluster.txt`。

宿主机代理、SSH 私钥、kubeconfig 和任何密码不提交仓库。代理地址不含认证信息。
