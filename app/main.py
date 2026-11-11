"""演示服务：FastAPI 单进程，可观测性示例。

业务 SLI 只统计 /work；/healthz、/readyz、/metrics 和 /version 不会写入
业务 request counter / histogram。故障参数在进程启动时从环境变量读取一次，
保存在不可变的 FaultConfig 中，请求处理绝不修改全局故障状态。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import platform
import random
import re
import sys
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from time import perf_counter
from typing import Any, Iterator

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

LOGGER_NAME = "demo_service"
BUSINESS_ROUTE = "/work"
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
MAX_LATENCY_MS = 60_000

logger = logging.getLogger(LOGGER_NAME)
logger.setLevel(logging.INFO)
logger.propagate = False
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(_handler)

HTTP_REQUESTS = Counter(
    "demo_http_requests_total",
    "Business HTTP requests by fixed route and status.",
    ["route", "status"],
)
HTTP_REQUEST_DURATION = Histogram(
    "demo_http_request_duration_seconds",
    "Business HTTP request latency in seconds.",
    ["route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)


class StartupError(RuntimeError):
    """启动配置非法或主动演练启动失败。"""


@dataclass(frozen=True)
class FaultConfig:
    error_rate: float
    latency_ms: int
    startup_fail: bool


@dataclass(frozen=True)
class AppConfig:
    app_version: str
    git_sha: str
    app_env: str
    faults: FaultConfig


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def log_event(level: int, event: str, **fields: Any) -> None:
    payload: dict[str, Any] = {
        "timestamp": utc_now(),
        "level": logging.getLevelName(level),
        "event": event,
    }
    payload.update(fields)
    logger.log(level, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _read_bool(name: str, default: str = "false") -> bool:
    raw = os.getenv(name, default).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise StartupError(f"{name} must be a boolean (true/false/1/0), got {raw!r}")


def _read_float(name: str, default: str) -> float:
    raw = os.getenv(name, default).strip()
    try:
        return float(raw)
    except ValueError as exc:
        raise StartupError(f"{name} must be a number, got {raw!r}") from exc


def _read_int(name: str, default: str) -> int:
    raw = os.getenv(name, default).strip()
    try:
        return int(raw)
    except ValueError as exc:
        raise StartupError(f"{name} must be an integer, got {raw!r}") from exc


def load_config() -> AppConfig:
    """读取并校验环境变量；任何非法值都让进程启动失败。"""
    error_rate = _read_float("DEMO_ERROR_RATE", "0")
    latency_ms = _read_int("DEMO_LATENCY_MS", "0")
    startup_fail = _read_bool("DEMO_STARTUP_FAIL", "false")

    if not 0.0 <= error_rate <= 1.0:
        raise StartupError(
            f"DEMO_ERROR_RATE must be between 0 and 1, got {error_rate!r}"
        )
    if not 0 <= latency_ms <= MAX_LATENCY_MS:
        raise StartupError(
            f"DEMO_LATENCY_MS must be between 0 and {MAX_LATENCY_MS}, "
            f"got {latency_ms!r}"
        )

    app_version = os.getenv("APP_VERSION", "dev").strip() or "dev"
    git_sha = os.getenv("GIT_SHA", "unknown").strip() or "unknown"
    app_env = os.getenv("APP_ENV", "development").strip() or "development"
    return AppConfig(
        app_version=app_version,
        git_sha=git_sha,
        app_env=app_env,
        faults=FaultConfig(
            error_rate=error_rate,
            latency_ms=latency_ms,
            startup_fail=startup_fail,
        ),
    )


def _request_id(request: Request) -> str:
    candidate = (request.headers.get("x-request-id") or "").strip()
    if REQUEST_ID_PATTERN.fullmatch(candidate):
        return candidate
    return uuid.uuid4().hex


@asynccontextmanager
async def lifespan(application: FastAPI) -> Iterator[None]:
    try:
        config = load_config()
    except StartupError as exc:
        log_event(logging.CRITICAL, "startup_failed", reason=str(exc))
        raise

    application.state.config = config
    application.state.ready = False
    if config.faults.startup_fail:
        log_event(
            logging.CRITICAL,
            "startup_failed",
            reason="DEMO_STARTUP_FAIL=true",
            app_version=config.app_version,
            git_sha=config.git_sha,
        )
        raise StartupError(
            "DEMO_STARTUP_FAIL=true: refusing to start (intentional drill)"
        )

    application.state.ready = True
    application.state.started_at = utc_now()
    log_event(
        logging.INFO,
        "startup",
        app_version=config.app_version,
        git_sha=config.git_sha,
        app_env=config.app_env,
        python_version=platform.python_version(),
        pid=os.getpid(),
        error_rate=config.faults.error_rate,
        latency_ms=config.faults.latency_ms,
    )
    if config.git_sha == "unknown" or config.app_version == "dev":
        log_event(
            logging.WARNING,
            "build_metadata_incomplete",
            message="APP_VERSION/GIT_SHA are not set to release values",
        )
    try:
        yield
    finally:
        application.state.ready = False
        log_event(logging.INFO, "shutdown", pid=os.getpid())


app = FastAPI(
    title="Observability Demo Service",
    description="Small FastAPI workload for the Ansible + Kubernetes observability demo.",
    version="0.1.0",
    lifespan=lifespan,
)


@app.middleware("http")
async def observe_request(request: Request, call_next: Any) -> Response:
    request_id = _request_id(request)
    request.state.request_id = request_id
    started = perf_counter()
    response: Response | None = None
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        duration = perf_counter() - started
        if response is not None:
            response.headers["X-Request-ID"] = request_id
        # 只观测业务路由，且 route 标签来自固定常量，避免 URL 路径导致基数爆炸。
        if request.url.path == BUSINESS_ROUTE:
            HTTP_REQUESTS.labels(
                route=BUSINESS_ROUTE, status=str(status_code)
            ).inc()
            HTTP_REQUEST_DURATION.labels(route=BUSINESS_ROUTE).observe(duration)
            log_event(
                logging.INFO,
                "request",
                path=request.url.path,
                route=BUSINESS_ROUTE,
                method=request.method,
                status=status_code,
                duration_seconds=round(duration, 6),
                request_id=request_id,
            )


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness：进程能响应即存活，不检查依赖。"""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz(request: Request) -> Response:
    """Readiness：只有启动校验通过且未在退出流程中才返回 200。"""
    if not getattr(request.app.state, "ready", False):
        return JSONResponse(status_code=503, content={"status": "not_ready"})
    return JSONResponse(status_code=200, content={"status": "ready"})


@app.get("/version")
async def version(request: Request) -> dict[str, str]:
    """发布验证入口；APP_VERSION/GIT_SHA 来自部署时注入的环境变量。"""
    config: AppConfig = request.app.state.config
    return {
        "app_version": config.app_version,
        "git_sha": config.git_sha,
        "app_env": config.app_env,
        "python_version": platform.python_version(),
        "started_at": getattr(request.app.state, "started_at", utc_now()),
    }


@app.get("/work")
async def work(request: Request) -> Response:
    """业务请求；按启动时固化的故障配置注入延迟与 500。"""
    config: AppConfig = request.app.state.config
    request_id: str = request.state.request_id
    faults = config.faults  # 局部只读引用，绝不修改全局配置

    if faults.latency_ms > 0:
        await asyncio.sleep(faults.latency_ms / 1000)

    if faults.error_rate >= 1.0 or (
        faults.error_rate > 0.0 and random.random() < faults.error_rate
    ):
        return JSONResponse(
            status_code=500,
            content={
                "status": "error",
                "error": "injected_failure",
                "request_id": request_id,
            },
        )

    return JSONResponse(
        status_code=200,
        content={
            "status": "ok",
            "work_id": uuid.uuid4().hex,
            "request_id": request_id,
            "app_version": config.app_version,
            "git_sha": config.git_sha,
        },
    )


@app.get("/metrics")
async def metrics() -> Response:
    """Prometheus 抓取端点；不会计入业务 SLI。"""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
