# Demo 服务与 Helm Chart

本目录交付阶段 2 的示例服务源码和 Chart，只覆盖 `app/`、`charts/demo/`、
`scripts/traffic.sh`、`scripts/acceptance/app.sh`、`.dockerignore` 与本文档。
不包含部署、镜像构建/发布或集群操作。目标环境为 Ubuntu 22.04、Kubernetes 1.37.2，
1 个带 `NoSchedule` taint 的 master 和 1 个运行工作负载的 worker。

> 当前部署已使用 GHCR 的不可变 `sha-c0bff8ab...`（与 `gitops/demo/values.yaml` 一致），Actions 已构建发布，集群运行验收 **7/7 PASS**。Chart 内的默认镜像值只是未配置环境的占位，不能当作本次部署值。
>
> 项目最终状态见 [README](../README.md)；示例服务的实际运行与测试证据见 `evidence/stage2-service.txt`、`evidence/service-unit-tests.txt`。

## 1. 组件与边界

| 路径 | 内容 |
| --- | --- |
| `app/main.py` | FastAPI 单进程服务，业务接口、探针、Prometheus 指标、JSON 日志 |
| `app/Dockerfile` | 固定 Python 3.13.9 补丁版和依赖版本，非 root、单 worker |
| `app/requirements.txt` | 固定直接依赖版本 |
| `app/requirements-dev.txt` | 追加 TestClient 所需的固定测试依赖 |
| `app/tests/test_main.py` | 接口/指标/日志/故障注入/启动失败测试（`unittest`） |
| `charts/demo/` | Deployment、ClusterIP Service、可选 ServiceMonitor |
| `scripts/traffic.sh` | 持续/限量正常 `/work` 流量，带限速、超时、退出条件 |
| `scripts/acceptance/app.sh` | 验收探针、指标、版本和 request_id，支持 port-forward 或 `BASE_URL` |

明确约束：

- 无数据库、无外部依赖、无 hostPath、无 NodePort、无 Ingress。
- 容器只监听 `8080`，单进程（`--workers 1`）。
- Chart 默认不设置 `nodeSelector`/`tolerations`，不硬编码 worker 主机名；
  master 的 `NoSchedule` taint 会让 Pod 留在 worker。
- ServiceMonitor 默认关闭；关闭时 Chart 不渲染该对象，不依赖
  `monitoring.coreos.com/v1` CRD。启用时才要求集群已安装 Prometheus Operator。

## 2. API

| 方法/路径 | 用途 | 是否计入业务 SLI | 说明 |
| --- | --- | --- | --- |
| `GET /healthz` | liveness | 否 | 进程可响应即 200 `{"status":"ok"}` |
| `GET /readyz` | readiness | 否 | 启动完成且未进入退出流程时 200 `{"status":"ready"}`，否则 503 |
| `GET /metrics` | Prometheus 抓取 | 否 | Prometheus text/OpenMetrics exposition |
| `GET /version` | 发布核对 | 否 | `app_version`、`git_sha`、`app_env`、`python_version`、`started_at` |
| `GET /work` | 业务请求 | 是 | 200 返回 `work_id`/`request_id`/版本；故障注入时可 500 |

`/work` 成功响应示例：

```json
{
  "status": "ok",
  "work_id": "0f1a...",
  "request_id": "acceptance-1234-1712345678",
  "app_version": "0.1.0",
  "git_sha": "abc1234"
}
```

故障注入返回：

```json
{"status":"error","error":"injected_failure","request_id":"..."}
```

`X-Request-ID` 请求头若匹配 `^[A-Za-z0-9._-]{1,64}$` 会被沿用，否则服务生成新的
UUID hex。所有响应都会回写 `X-Request-ID`。业务日志与 `/work` JSON 中的
`request_id` 一致，便于日志/指标/链路关联。

## 3. 环境变量与故障演练

| 变量 | 默认 | 约束 | 作用 |
| --- | --- | --- | --- |
| `APP_VERSION` | `dev` | 空值回退 `dev` | 发布版本，`/version` 与 `/work` 可读 |
| `GIT_SHA` | `unknown` | 空值回退 `unknown` | 发布提交，`/version` 与 `/work` 可读 |
| `APP_ENV` | `development` | 非空字符串 | 环境标识 |
| `DEMO_ERROR_RATE` | `0` | `0..1` | `/work` 注入 HTTP 500 的概率；`1` 为必失败 |
| `DEMO_LATENCY_MS` | `0` | `0..60000` | `/work` 处理前注入的延迟毫秒数 |
| `DEMO_STARTUP_FAIL` | `false` | `true/false/1/0/yes/no/on/off` | 为 true 时打印明确启动失败日志并退出 |

启动时一次性读取并校验环境变量，保存在不可变的配置对象中。非法值会写
`startup_failed` 日志并以非 0 退出。请求处理只读取该配置，**不会**在全局临时修改
故障参数，因此并发请求安全，rollout 后的所有副本使用同一组 env。

故障配置必须通过 Deployment 的 Pod template 变更生效，例如
`values.yaml` 的 `env` 或 `extraEnv` 配合 `helm upgrade`（Deployment 自动 rollout），
或 `kubectl rollout restart`。脚本不会修改 Deployment 或故障参数。

故障演练示例（只在受限 namespace 中执行，不要 reset 集群）：

```bash
# 注入 100% 500，观察错误率和日志
helm upgrade demo charts/demo -n observability \
  --reuse-values --set-string env.DEMO_ERROR_RATE=1

# 恢复
helm upgrade demo charts/demo -n observability \
  --reuse-values --set-string env.DEMO_ERROR_RATE=0
```

启动失败演练会把 Pod 带入 CrashLoop，日志应出现 `startup_failed` 和
`DEMO_STARTUP_FAIL=true`；演练后立即恢复：

```bash
helm upgrade demo charts/demo -n observability \
  --reuse-values --set-string env.DEMO_STARTUP_FAIL=true

helm upgrade demo charts/demo -n observability \
  --reuse-values --set-string env.DEMO_STARTUP_FAIL=false
```

## 4. 日志

每个 `/work` 请求输出一行 JSON 到 stdout，字段固定包含 UTC 时间、path、status、
`duration_seconds` 和 `request_id`：

```json
{"timestamp":"2026-11-11T08:00:00.123Z","level":"INFO","event":"request","path":"/work","route":"/work","method":"GET","status":200,"duration_seconds":0.001234,"request_id":"..."}
```

`/healthz`、`/readyz`、`/metrics`、`/version` 不产生业务 request 日志，避免探针
噪声。启动时输出 `startup`，退出时输出 `shutdown`；启动失败/配置错误输出
`startup_failed`（critical）。Dockerfile 已关闭 uvicorn access log，避免非 JSON
的重复访问日志。

## 5. 指标与 SLI

业务指标只有 `/work` 写入，固定标签，不使用原始 URL 路径：

| 指标 | 类型 | 标签 |
| --- | --- | --- |
| `demo_http_requests_total` | Counter | `route="/work"`、`status="200|500|..."` |
| `demo_http_request_duration_seconds` | Histogram | `route="/work"` |

因此 `/healthz`、`/readyz`、`/metrics`、`/version` 和任意 404 路径不会污染业务
SLI，也不会造成路径标签基数无限增长。常用 PromQL：

```promql
sum(rate(demo_http_requests_total{route="/work",status=~"5.."}[5m]))
/
sum(rate(demo_http_requests_total{route="/work"}[5m]))

histogram_quantile(
  0.95,
  sum by (le) (rate(demo_http_request_duration_seconds_bucket{route="/work"}[5m]))
)
```

Chart 的 Service 和 Pod 带 `app.kubernetes.io/name`、`app.kubernetes.io/instance`、
`app.kubernetes.io/component=demo-service`、`app.kubernetes.io/part-of=observability-demo`
等标签。ServiceMonitor 的 `selector.matchLabels` 与 Service 一致；监控组件的
`serviceMonitorSelector` 稍后协调时，可通过 `serviceMonitor.labels`（例如
`release: kube-prometheus-stack`）补充选择标签。监控 sidecar/operator 的抓取
namespace 配置不在本 Chart 范围内。

## 6. Chart 使用

关键 values：

```yaml
image:
  repository: registry.example.com/observability/demo
  tag: "0.1.0"          # 留空时回退到 Chart.appVersion
appVersion: "0.1.0"     # 写入 APP_VERSION；留空回退 Chart.appVersion
gitSha: "abc1234"       # 写入 GIT_SHA
env:
  DEMO_ERROR_RATE: "0"
  DEMO_LATENCY_MS: "0"
  DEMO_STARTUP_FAIL: "false"
serviceMonitor:
  enabled: false
```

先做离线渲染检查（需要 helm；本机未安装时不要伪造结果）：

```bash
helm lint charts/demo
helm template demo charts/demo -n observability
helm template demo charts/demo -n observability \
  --set serviceMonitor.enabled=true --set serviceMonitor.labels.release=kube-prometheus-stack
```

安装时显式传入实际镜像和可追溯版本（镜像必须先构建并 push 到集群可拉取的仓库）：

```bash
helm upgrade --install demo charts/demo -n observability --create-namespace \
  --set image.repository=registry.example.com/observability/demo \
  --set image.tag=0.1.0 \
  --set appVersion=0.1.0 \
  --set gitSha="$(git rev-parse --short HEAD)"
```

安全与调度默认值：

- Pod/容器 `runAsNonRoot`、UID/GID `10001`、`readOnlyRootFilesystem: true`、
  `allowPrivilegeEscalation: false`、`capabilities.drop: [ALL]`、
  `seccompProfile: RuntimeDefault`。
- `/tmp` 使用内存 `emptyDir`，兼容只读根文件系统；无 hostPath。
- requests `50m/64Mi`，limits `250m/192Mi`，可按集群容量调整。
- 只创建 ClusterIP Service，端口 `8080`；不提供 NodePort/Ingress。
- 默认 `tolerations: []`，不要为了“能调度”而容忍 master taint；若需要固定到
  worker，用节点标签/`nodeSelector` 由环境侧配置，不写死主机名。

### ServiceMonitor 依赖

`serviceMonitor.enabled=false`（默认）时，Chart 只渲染 Deployment 和 Service，
`helm template`/安装不要求 CRD。设为 `true` 前必须确认：

1. 集群已有 `monitoring.coreos.com/v1` CRD；
2. Prometheus 实例的 `serviceMonitorSelector` 能匹配 Chart 标签或
   `serviceMonitor.labels`；
3. Prometheus 的 `serviceMonitorNamespaceSelector` 覆盖 release 或
   `serviceMonitor.namespace`。

否则对象会因 CRD 不存在或无人选取而失败/无效。

## 7. 镜像构建

构建上下文为仓库根目录：

```bash
docker build -f app/Dockerfile -t registry.example.com/observability/demo:0.1.0 .
```

Dockerfile 使用 `python:3.13.9-slim-bookworm`，先安装固定版本依赖再复制源码，
以 UID/GID 10001 非 root 运行，`EXPOSE 8080`，单 worker。Python 3.13 仍在安全
支持期，但镜像**未在本阶段构建**；CI 中应补充构建、漏洞扫描、推送和镜像摘要
固定（后续由操作者安排）。若使用 digest 固定，需要在 Chart 中增加 digest 支持
或把 tag 写成不可变 digest 引用，当前 Chart 只支持 repository/tag。

## 8. 本地/转发验收

`scripts/acceptance/app.sh` 会实际执行 HTTP 检查，而不是只打印命令：

- `/healthz` 200 且 `status=ok`；
- `/readyz` 200 且 `status=ready`；
- `/metrics` 200，存在业务 counter/histogram；
- `/version` 200，`app_version`/`git_sha` 非空，可选断言期望值；
- `/work` 200，JSON 中 `request_id` 与发送的 `X-Request-ID`、响应头一致；
- `/work` 后 `route="/work",status="200"` counter 严格增加；
- 确认没有 `route="/healthz"`、`route="/readyz"` 标签；
- 任一检查失败返回非 0；
- 默认按 `app.kubernetes.io/instance=<release>` 和
  `app.kubernetes.io/component=demo-service` 找到唯一 Service，建立本脚本自己的
  `kubectl port-forward`，退出时 kill 该 PID；也支持 `BASE_URL` 完全绕过 kubectl。
- 若文件检出后没有执行位，用 `bash scripts/acceptance/app.sh ...` 调用。

```bash
# 选定 release，自动 port-forward
scripts/acceptance/app.sh --release demo --namespace observability \
  --expect-version 0.1.0 --expect-git-sha abc1234

# 已有本地转发/Ingress 之外的直连地址
BASE_URL=http://127.0.0.1:18080 scripts/acceptance/app.sh \
  --expect-version 0.1.0

# 手工验证
kubectl -n observability port-forward svc/demo 18080:8080
curl -i http://127.0.0.1:18080/healthz
curl -s http://127.0.0.1:18080/version | python3 -m json.tool
```

## 9. 流量脚本

`scripts/traffic.sh` 只发 `/work` 正常 GET，不会通过脚本改故障参数或集群资源。
若文件检出后没有执行位，用 `bash scripts/traffic.sh ...` 调用。

```bash
# 每秒 5 次，运行 60 秒
scripts/traffic.sh --base-url http://127.0.0.1:18080 --rate 5 --duration 60

# 发 200 个请求后退出，不限速
scripts/traffic.sh --base-url http://127.0.0.1:18080 --requests 200 --rate 0

# 故障演练期间允许 500/传输错误，不因此返回失败
scripts/traffic.sh --base-url http://127.0.0.1:18080 --rate 2 --duration 30 --allow-errors
```

特性与语义：

- `--duration`/`--requests` 控制退出，`--rate 0` 为不限速，默认有限速；
- 每请求有 connect/max time 超时；
- 每行记录 UTC 时间、HTTP status、耗时、request_id、序号和 URL，可 `--log-file` 追加；
- 传输错误或非 2xx 默认最终返回非 0；演练时用 `--allow-errors`；
- Ctrl-C/TERM 会停止循环、输出 summary，并以 130/143 退出；
- 不执行 kubectl，不 reset 集群，不修改 Deployment/env。

## 10. 测试与已知未验证项

本机可运行（不访问集群，不需要 pytest）：

```bash
python -m pip install -r app/requirements-dev.txt
python -m unittest discover -s app/tests -v
```

测试覆盖：健康/就绪/版本、`/work` 成功与 request_id、JSON 日志字段、固定 route
指标及探针隔离、500+延迟注入、启动失败日志与拒启、非法 error rate、故障配置
不可变。

实际结果与剩余边界：

- 8 项单元测试全部通过，证据 `evidence/service-unit-tests.txt`。
- 集群运行验收 7/7：探针、`/version`、`/metrics`、`/work` request_id、状态码计数、探针不写 SLI，证据 `evidence/stage2-service.txt`。
- 镜像已由 Actions 构建并推送到 GHCR，使用 `sha-<commit>` 不可变 tag；未使用 `latest`。
- 已在 worker 上运行，Prometheus 通过 ServiceMonitor 抓取 demo，`--phase metrics` 16/16 覆盖真实样本与 target up。
- 容器仍以非 root、只读根文件系统运行；具体安全上下文以 Chart 和集群实际 Pod 为准。
- Chart 只支持 `image.repository + image.tag`，尚不支持 digest 引用；当前用不可变 SHA tag。
- 传递依赖由 pip 在构建时解析；直接依赖已用 `==` 固定，若要更强可复现性，CI 可再加锁文件校验。
