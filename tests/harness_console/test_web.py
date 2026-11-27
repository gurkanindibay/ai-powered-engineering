"""HTTP endpoint, SSE, loopback-only, and CSRF/Origin security tests for web.py."""
from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request

from scripts.harness_console.store import ConsoleError
from scripts.harness_console.web import create_server
from tests.harness_console.fixtures import SyntheticHarnessEnv


class ConsoleWebTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = SyntheticHarnessEnv()
        self.service = self.env.make_service()
        self.server = create_server(self.service, host="127.0.0.1", port=0)
        self.port = self.server.server_address[1]
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)
        self.service.close()
        self.env.cleanup()

    def _request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            method=method,
            headers=headers or {},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, dict(resp.headers.items()), resp.read()
        except urllib.error.HTTPError as err:
            try:
                return err.code, dict(err.headers.items()), err.read()
            finally:
                err.close()

    def test_refuses_non_loopback_bind(self) -> None:
        with self.assertRaises(ConsoleError):
            create_server(self.service, host="0.0.0.0", port=0)
        with self.assertRaises(ConsoleError):
            create_server(self.service, host="192.168.1.50", port=0)

    def test_get_endpoints_and_sse_stream(self) -> None:
        status, _, body = self._request("/")
        self.assertEqual(status, 200)
        self.assertIn(b"Harness Control Console", body)

        status, _, body = self._request("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

        status, _, body = self._request("/api/status")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["board"]["items"][0]["issue"], 550)

        status, _, body = self._request(f"/api/timeline?issue=550&run={self.env.run_id}")
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(json.loads(body)["events"]), 2)

        status, _, body = self._request("/api/pickups")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["count"], 1)

        status, headers, body = self._request("/api/stream?issue=550&once=1")
        self.assertEqual(status, 200)
        self.assertIn("text/event-stream", headers.get("Content-Type", ""))
        self.assertIn(b"event: log\n", body)
        self.assertIn(b"event: status\n", body)
        self.assertNotIn(b"SECRET_SHOULD_BE_REDACTED", body)

    def test_csrf_host_origin_referer_and_content_type_guards(self) -> None:
        # 1. DNS rebinding Host header rejected.
        status, _, _ = self._request("/api/status", headers={"Host": "evil.example:9096"})
        self.assertEqual(status, 403)

        # 2. Cross-origin Origin rejected on POST.
        status, _, _ = self._request(
            "/api/pause",
            method="POST",
            body=b'{"all":true}',
            headers={"Content-Type": "application/json", "Origin": "https://evil.example"},
        )
        self.assertEqual(status, 403)

        # 3. Cross-port loopback Origin rejected on POST.
        status, _, _ = self._request(
            "/api/pause",
            method="POST",
            body=b'{"all":true}',
            headers={"Content-Type": "application/json", "Origin": f"http://127.0.0.1:{self.port + 1}"},
        )
        self.assertEqual(status, 403)

        # 4. Cross-site Referer or Sec-Fetch-Site rejected on POST.
        status, _, _ = self._request(
            "/api/pause",
            method="POST",
            body=b'{"all":true}',
            headers={"Content-Type": "application/json", "Sec-Fetch-Site": "cross-site"},
        )
        self.assertEqual(status, 403)

        status, _, _ = self._request(
            "/api/pause",
            method="POST",
            body=b'{"all":true}',
            headers={"Content-Type": "application/json", "Referer": "http://localhost:9999/attack"},
        )
        self.assertEqual(status, 403)

        # 5. Non-JSON Content-Type rejected (415) so browser simple-requests fail.
        status, _, _ = self._request(
            "/api/pause",
            method="POST",
            body=b"all=true",
            headers={"Content-Type": "application/x-www-form-urlencoded", "Origin": self.base_url},
        )
        self.assertEqual(status, 415)

        # 6. OPTIONS preflight rejected (405).
        status, _, _ = self._request("/api/pause", method="OPTIONS")
        self.assertEqual(status, 405)

    def test_post_interventions_with_same_origin(self) -> None:
        headers = {
            "Content-Type": "application/json",
            "Origin": self.base_url,
            "Sec-Fetch-Site": "same-origin",
        }
        for path, body in (
            ("/api/pause", {"issue": 550}),
            ("/api/steer", {"issue": 550, "note": "Keep decimal strings"}),
            ("/api/handover", {"issue": 550, "to": "codex"}),
            ("/api/set-budget", {"provider": "copilot-deepseek", "usd": "35.00"}),
            ("/api/set-gate", {"tier": "critical", "require_approval": True}),
            ("/api/approve", {"issue": 550}),
            ("/api/resume", {"issue": 550}),
            ("/api/kill", {"run_id": self.env.run_id}),
        ):
            status, _, resp = self._request(path, method="POST", body=json.dumps(body).encode("utf-8"), headers=headers)
            self.assertEqual(status, 200, f"{path} returned {resp!r}")
            self.assertTrue(json.loads(resp)["ok"])

        status, _, cmds_raw = self._request("/api/commands?limit=20")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(cmds_raw)["count"], 8)


if __name__ == "__main__":
    unittest.main()
