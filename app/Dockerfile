# syntax=docker/dockerfile:1.7
# 固定 Python 3.13 补丁版本（3.13 仍在安全支持期），不使用 latest。
FROM python:3.13.9-slim-bookworm

ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ENV APP_VERSION=${APP_VERSION} GIT_SHA=${GIT_SHA}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HOME=/tmp \
    TMPDIR=/tmp

WORKDIR /app

# 先只复制依赖清单，源码变化可复用依赖层。
COPY app/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# 仅复制运行所需源码，测试与文档不进入镜像。
COPY app/__init__.py /app/app/__init__.py
COPY app/main.py /app/app/main.py

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

USER 10001:10001
EXPOSE 8080

# 单 worker、单进程；关闭 uvicorn access log，业务日志由应用以 JSON 输出。
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--no-access-log", "--log-level", "info"]
