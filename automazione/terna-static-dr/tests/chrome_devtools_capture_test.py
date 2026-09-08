#!/usr/bin/env python3
"""Offline tests for the Chromium DevTools adapter used by Terna capture."""

from __future__ import annotations

import base64
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


HOST_FETCH = Path(__file__).parents[1] / "host-fetch"
sys.path.insert(0, str(HOST_FETCH))

import chrome_devtools_capture as chrome  # noqa: E402
from load_chart_capture import CaptureError, CapturePolicy  # noqa: E402


class FakeSession:
    def __init__(self, states: list[dict[str, object]]) -> None:
        self.states = iter(states)
        self.calls: list[tuple[str, dict[str, object]]] = []

    def call(
        self, method: str, params: dict[str, object] | None = None
    ) -> dict[str, object]:
        self.calls.append((method, params or {}))
        if method == "Page.navigate":
            return {"frameId": "main"}
        if method == "Runtime.evaluate":
            return {"result": {"value": next(self.states)}}
        if method == "Page.captureScreenshot":
            return {"data": base64.b64encode(b"captured png").decode("ascii")}
        return {}


class CommandTests(unittest.TestCase):
    def test_chrome_uses_an_ephemeral_devtools_port_and_pins_only_terna(self) -> None:
        command = chrome.build_chrome_command(
            "/usr/bin/google-chrome",
            Path("/tmp/profile"),
            "93.184.216.34",
        )

        self.assertIn("--remote-debugging-port=0", command)
        self.assertNotIn("--remote-debugging-port=9222", command)
        self.assertIn(
            "--host-resolver-rules=MAP www.terna.it 93.184.216.34,"
            "MAP terna.it 93.184.216.34,EXCLUDE localhost",
            command,
        )
        self.assertEqual(command[-1], "about:blank")

    def test_devtools_port_file_is_strictly_validated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            port_file = Path(temporary) / "DevToolsActivePort"
            port_file.write_text("43123\n/devtools/browser/id\n", encoding="utf-8")
            self.assertEqual(chrome.read_devtools_port(port_file), 43123)

            for value in ("", "not-a-port\n", "0\n", "70000\n"):
                with self.subTest(value=value):
                    port_file.write_text(value, encoding="utf-8")
                    with self.assertRaises(CaptureError):
                        chrome.read_devtools_port(port_file)

    def test_root_process_prepares_a_non_privileged_browser_identity(self) -> None:
        ownership_changes: list[tuple[Path, int, int]] = []
        mode_changes: list[tuple[Path, int]] = []

        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "attempt"
            profile = workspace / "profile"
            profile.mkdir(parents=True)
            account = mock.Mock(pw_uid=65534, pw_gid=65534)

            identity = chrome.prepare_browser_identity(
                workspace.parent.parent,
                workspace,
                profile,
                platform="posix",
                effective_uid=0,
                user_lookup=lambda _: account,
                change_owner=lambda path, uid, gid: ownership_changes.append(
                    (Path(path), uid, gid)
                ),
                change_mode=lambda path, mode: mode_changes.append((Path(path), mode)),
            )

        self.assertEqual(identity, chrome.BrowserIdentity(65534, 65534))
        self.assertEqual(
            ownership_changes,
            [(workspace, 65534, 65534), (profile, 65534, 65534)],
        )
        self.assertEqual(
            mode_changes,
            [(workspace.parent.parent, 0o711), (workspace.parent, 0o711)],
        )

    def test_failed_websocket_handshake_closes_the_socket(self) -> None:
        connection = mock.Mock()
        with mock.patch.object(
            chrome.socket, "create_connection", return_value=connection
        ), mock.patch.object(
            chrome,
            "_read_http_upgrade",
            side_effect=CaptureError("bad handshake"),
        ):
            with self.assertRaisesRegex(CaptureError, "bad handshake"):
                chrome._WebSocketConnection.connect(
                    "ws://127.0.0.1:43123/devtools/page/id",
                    5,
                )

        connection.close.assert_called_once_with()


class DriveCaptureTests(unittest.TestCase):
    def test_monitor_is_installed_before_navigation_and_render_is_semantic(self) -> None:
        session = FakeSession(
            [
                {
                    "document_ready": True,
                    "iframe_ready": True,
                    "rendered": False,
                    "error": None,
                },
                {
                    "document_ready": True,
                    "iframe_ready": True,
                    "rendered": True,
                    "error": None,
                },
            ]
        )
        delays: list[float] = []

        with tempfile.TemporaryDirectory() as temporary:
            screenshot = Path(temporary) / "chart.png"
            chrome.drive_capture(
                session,
                screenshot,
                CapturePolicy(
                    render_timeout_seconds=5,
                    poll_interval_seconds=0.5,
                    settle_seconds=0.25,
                ),
                sleeper=delays.append,
            )
            self.assertEqual(screenshot.read_bytes(), b"captured png")

        methods = [method for method, _ in session.calls]
        self.assertLess(
            methods.index("Page.addScriptToEvaluateOnNewDocument"),
            methods.index("Page.navigate"),
        )
        self.assertEqual(methods.count("Runtime.evaluate"), 2)
        self.assertEqual(delays, [0.5, 0.25])

    def test_navigation_error_stops_before_screenshot(self) -> None:
        class FailedNavigationSession(FakeSession):
            def call(
                self, method: str, params: dict[str, object] | None = None
            ) -> dict[str, object]:
                result = super().call(method, params)
                if method == "Page.navigate":
                    return {"frameId": "main", "errorText": "net::ERR_TIMED_OUT"}
                return result

        session = FailedNavigationSession([])

        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            CaptureError, "ERR_TIMED_OUT"
        ):
            chrome.drive_capture(
                session,
                Path(temporary) / "chart.png",
                CapturePolicy(),
            )

        self.assertNotIn("Page.captureScreenshot", [method for method, _ in session.calls])

    def test_malformed_runtime_state_is_rejected_instead_of_becoming_ready(self) -> None:
        with self.assertRaisesRegex(CaptureError, "readiness payload"):
            chrome.decode_report_state({"result": {"value": "ready"}})


if __name__ == "__main__":
    unittest.main()
