"""演示服务的关键行为测试。

运行（仓库根目录）：
    python -m unittest discover -s app/tests -v
测试只使用标准库 unittest 与 FastAPI TestClient，不访问集群。
"""

from __future__ import annotations

import json
import os
import sys
import unittest
from contextlib import contextmanager
from dataclasses import FrozenInstanceError
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import (  # noqa: E402
    StartupError,
    app,
    load_config,
)

BASE_ENV = {
    "APP_VERSION": "test-1.2.3",
    "GIT_SHA": "0123456789abcdef",
    "APP_ENV": "test",
    "DEMO_ERROR_RATE": "0",
    "DEMO_LATENCY_MS": "0",
    "DEMO_STARTUP_FAIL": "false",
}


@contextmanager
def service_env(**overrides: str):
    values = dict(BASE_ENV)
    values.update(overrides)
    with mock.patch.dict(os.environ, values, clear=False):
        yield


def log_payloads(records) -> list[dict]:
    payloads = []
    for record in records:
        message = record.getMessage()
        if message.startswith("{"):
            payloads.append(json.loads(message))
    return payloads


class DemoServiceTests(unittest.TestCase):
    def test_health_readiness_and_version(self) -> None:
        with service_env():
            with TestClient(app) as client:
                health = client.get("/healthz")
                self.assertEqual(health.status_code, 200)
                self.assertEqual(health.json(), {"status": "ok"})

                ready = client.get("/readyz")
                self.assertEqual(ready.status_code, 200)
                self.assertEqual(ready.json(), {"status": "ready"})

                version = client.get("/version")
                self.assertEqual(version.status_code, 200)
                body = version.json()
                self.assertEqual(body["app_version"], "test-1.2.3")
                self.assertEqual(body["git_sha"], "0123456789abcdef")
                self.assertTrue(body["python_version"])

    def test_readiness_returns_503_while_liveness_stays_200(self) -> None:
        with service_env():
            with TestClient(app) as client:
                app.state.ready = False
                self.assertEqual(client.get("/readyz").status_code, 503)
                self.assertEqual(client.get("/healthz").status_code, 200)

    def test_work_success_logs_json_and_counts_fixed_route(self) -> None:
        with service_env():
            with self.assertLogs("demo_service", level="INFO") as captured:
                with TestClient(app) as client:
                    response = client.get(
                        "/work", headers={"X-Request-ID": "req-test-1"}
                    )
                    self.assertEqual(response.status_code, 200)
                    body = response.json()
                    self.assertEqual(body["status"], "ok")
                    self.assertEqual(body["request_id"], "req-test-1")
                    self.assertEqual(
                        response.headers["x-request-id"], "req-test-1"
                    )
                    self.assertEqual(body["app_version"], "test-1.2.3")

                    metrics = client.get("/metrics").text

        self.assertIn(
            'demo_http_requests_total{route="/work",status="200"}', metrics
        )
        self.assertIn('demo_http_request_duration_seconds_count{route="/work"}', metrics)

        request_logs = [
            entry for entry in log_payloads(captured.records)
            if entry.get("event") == "request"
        ]
        self.assertEqual(len(request_logs), 1)
        entry = request_logs[0]
        self.assertTrue(entry["timestamp"].endswith("Z"))
        self.assertEqual(entry["path"], "/work")
        self.assertEqual(entry["status"], 200)
        self.assertEqual(entry["request_id"], "req-test-1")
        self.assertGreaterEqual(entry["duration_seconds"], 0)

    def test_injected_failure_and_latency(self) -> None:
        with service_env(DEMO_ERROR_RATE="1", DEMO_LATENCY_MS="20"):
            with self.assertLogs("demo_service", level="INFO") as captured:
                with TestClient(app) as client:
                    response = client.get("/work")
                    metrics = client.get("/metrics").text

        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json()["error"], "injected_failure")
        self.assertEqual(response.json()["request_id"], response.headers["x-request-id"])
        self.assertIn(
            'demo_http_requests_total{route="/work",status="500"}', metrics
        )
        entries = log_payloads(captured.records)
        request_entries = [e for e in entries if e.get("event") == "request"]
        self.assertEqual(request_entries[-1]["status"], 500)

    def test_probes_and_unknown_paths_do_not_create_sli_labels(self) -> None:
        with service_env():
            with TestClient(app) as client:
                client.get("/healthz")
                client.get("/readyz")
                client.get("/version")
                client.get("/metrics")
                client.get("/not-a-real-path")
                client.get("/work")
                metrics = client.get("/metrics").text

        self.assertNotIn('route="/healthz"', metrics)
        self.assertNotIn('route="/readyz"', metrics)
        self.assertNotIn('route="/not-a-real-path"', metrics)
        self.assertIn('route="/work"', metrics)

    def test_startup_failure_logs_and_exits(self) -> None:
        with service_env(DEMO_STARTUP_FAIL="true"):
            with self.assertLogs("demo_service", level="CRITICAL") as captured:
                with self.assertRaises((StartupError, RuntimeError)):
                    with TestClient(app):
                        pass

        entries = log_payloads(captured.records)
        failures = [e for e in entries if e.get("event") == "startup_failed"]
        self.assertTrue(failures)
        self.assertIn("DEMO_STARTUP_FAIL", failures[-1]["reason"])

    def test_invalid_error_rate_refuses_startup(self) -> None:
        with service_env(DEMO_ERROR_RATE="1.5"):
            with self.assertLogs("demo_service", level="CRITICAL"):
                with self.assertRaises((StartupError, RuntimeError)):
                    with TestClient(app):
                        pass

    def test_fault_config_is_immutable(self) -> None:
        with service_env():
            config = load_config()
        self.assertEqual(config.faults.error_rate, 0.0)
        with self.assertRaises(FrozenInstanceError):
            config.faults.error_rate = 1.0  # type: ignore[misc]


if __name__ == "__main__":
    unittest.main(verbosity=2)
