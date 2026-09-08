#!/usr/bin/env python3
"""Chromium DevTools adapter for the Terna Power BI screenshot use case."""

from __future__ import annotations

import base64
import binascii
from collections.abc import Callable
from dataclasses import dataclass
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
from typing import Protocol
from urllib.parse import urlsplit

from load_chart_capture import (
    CaptureError,
    CapturePolicy,
    ReportState,
    validate_origin_ip,
    wait_for_report_ready,
)


CHART_URL = (
    "https://www.terna.it/Portals/0/Resources/sistemaelettrico/"
    "trasparencyreport/Load-Curva-di-Carico-se.html"
)
MAX_DEVTOOLS_PAYLOAD_BYTES = 64 * 1024 * 1024
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

READINESS_MONITOR_SCRIPT = r"""
(() => {
  const state = window.__ternaCaptureState = {
    attached: false,
    loaded: false,
    rendered: false,
    error: null
  };
  const describeError = (event) => {
    const detail = event && event.detail ? event.detail : {};
    return String(detail.message || detail.errorCode || "Power BI reported an error").slice(0, 300);
  };
  const attach = () => {
    if (state.attached) return;
    const container = document.getElementById("load-curva");
    if (!container || !window.powerbi || typeof window.powerbi.get !== "function") return;
    try {
      const report = window.powerbi.get(container);
      if (!report || typeof report.on !== "function") return;
      state.attached = true;
      report.on("loaded", () => { state.loaded = true; });
      report.on("rendered", () => { state.loaded = true; state.rendered = true; });
      report.on("error", (event) => { state.error = describeError(event); });
    } catch (_) {
      // The embed is created asynchronously; the next poll retries attachment.
    }
  };
  const timer = window.setInterval(attach, 100);
  document.addEventListener("DOMContentLoaded", attach);
  window.addEventListener("beforeunload", () => window.clearInterval(timer), {once: true});
})();
"""

READINESS_PROBE_SCRIPT = r"""
(() => {
  const container = document.getElementById("load-curva");
  const iframe = container ? container.querySelector("iframe") : null;
  const rect = iframe ? iframe.getBoundingClientRect() : null;
  const state = window.__ternaCaptureState || {};
  return {
    document_ready: document.readyState === "complete",
    iframe_ready: Boolean(iframe && rect && rect.width >= 800 && rect.height >= 400),
    loaded: state.loaded === true,
    rendered: state.rendered === true,
    error: state.error || null
  };
})()
"""


class DevToolsSession(Protocol):
    def call(
        self, method: str, params: dict[str, object] | None = None
    ) -> dict[str, object]: ...


@dataclass(frozen=True)
class BrowserIdentity:
    uid: int
    gid: int


def prepare_browser_identity(
    runtime_root: Path,
    workspace: Path,
    profile: Path,
    *,
    platform: str | None = None,
    effective_uid: int | None = None,
    user_lookup: Callable[[str], object] | None = None,
    change_owner: Callable[[Path, int, int], None] | None = None,
    change_mode: Callable[[Path, int], None] | None = None,
) -> BrowserIdentity | None:
    """Drop only the remote-content browser when the service itself is root."""
    current_platform = platform or os.name
    if current_platform != "posix":
        return None
    current_uid = os.geteuid() if effective_uid is None else effective_uid
    if current_uid != 0:
        return None
    resolved_root = runtime_root.resolve()
    resolved_workspace = workspace.resolve()
    resolved_profile = profile.resolve()
    if (
        resolved_workspace.parent.parent != resolved_root
        or resolved_profile.parent != resolved_workspace
    ):
        raise CaptureError("Chrome workspace is outside the capture runtime root")
    if user_lookup is None:
        import pwd

        user_lookup = pwd.getpwnam
    account = user_lookup("nobody")
    identity = BrowserIdentity(int(account.pw_uid), int(account.pw_gid))
    owner = change_owner or os.chown
    set_mode = change_mode or os.chmod
    set_mode(runtime_root, 0o711)
    set_mode(workspace.parent, 0o711)
    owner(workspace, identity.uid, identity.gid)
    owner(profile, identity.uid, identity.gid)
    return identity


def build_chrome_command(
    browser_command: str,
    profile: Path,
    origin_ip: str,
) -> list[str]:
    pinned_ip = validate_origin_ip(origin_ip)
    return [
        browser_command,
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--disable-breakpad",
        "--disable-crash-reporter",
        "--disable-features=Crashpad",
        "--hide-scrollbars",
        "--window-size=1600,1000",
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=0",
        "--remote-allow-origins=http://127.0.0.1:*",
        f"--user-data-dir={profile}",
        (
            "--host-resolver-rules="
            f"MAP www.terna.it {pinned_ip},MAP terna.it {pinned_ip},EXCLUDE localhost"
        ),
        "about:blank",
    ]


def read_devtools_port(port_file: Path) -> int:
    try:
        first_line = port_file.read_text(encoding="utf-8").splitlines()[0]
        port = int(first_line)
    except (OSError, ValueError, IndexError) as error:
        raise CaptureError("Chrome wrote an invalid DevTools port file") from error
    if not 1 <= port <= 65535:
        raise CaptureError("Chrome wrote a DevTools port outside the valid range")
    return port


def decode_report_state(result: dict[str, object]) -> ReportState:
    remote_result = result.get("result")
    value = remote_result.get("value") if isinstance(remote_result, dict) else None
    if not isinstance(value, dict):
        raise CaptureError("Chrome returned an invalid Power BI readiness payload")
    error = value.get("error")
    return ReportState(
        document_ready=value.get("document_ready") is True,
        iframe_ready=value.get("iframe_ready") is True,
        rendered=value.get("rendered") is True,
        error=str(error)[:300] if error else None,
        loaded=value.get("loaded") is True,
    )


def drive_capture(
    session: DevToolsSession,
    screenshot: Path,
    policy: CapturePolicy,
    *,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    session.call("Page.enable")
    session.call("Runtime.enable")
    session.call(
        "Page.addScriptToEvaluateOnNewDocument",
        {"source": READINESS_MONITOR_SCRIPT},
    )
    navigation = session.call("Page.navigate", {"url": CHART_URL})
    if navigation.get("errorText"):
        raise CaptureError(f"Terna chart navigation failed: {navigation['errorText']}")

    def probe() -> ReportState:
        result = session.call(
            "Runtime.evaluate",
            {
                "expression": READINESS_PROBE_SCRIPT,
                "returnByValue": True,
                "awaitPromise": True,
            },
        )
        return decode_report_state(result)

    wait_for_report_ready(probe, policy, sleeper=sleeper)
    sleeper(policy.settle_seconds)
    result = session.call(
        "Page.captureScreenshot",
        {"format": "png", "fromSurface": True, "captureBeyondViewport": False},
    )
    encoded = result.get("data")
    if not isinstance(encoded, str):
        raise CaptureError("Chrome returned no screenshot data")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise CaptureError("Chrome returned invalid screenshot data") from error
    screenshot.write_bytes(payload)


class _WebSocketConnection:
    def __init__(self, connection: socket.socket, buffered: bytes = b"") -> None:
        self._connection = connection
        self._buffer = bytearray(buffered)

    @classmethod
    def connect(cls, endpoint: str, timeout: float) -> _WebSocketConnection:
        parsed = urlsplit(endpoint)
        if parsed.scheme != "ws" or parsed.hostname not in {"127.0.0.1", "localhost"}:
            raise CaptureError("Chrome returned an unsafe DevTools WebSocket endpoint")
        if parsed.port is None:
            raise CaptureError("Chrome returned a DevTools endpoint without a port")
        connection = socket.create_connection((parsed.hostname, parsed.port), timeout)
        try:
            connection.settimeout(timeout)
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
            request = (
                f"GET {path} HTTP/1.1\r\nHost: {parsed.netloc}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode("ascii")
            connection.sendall(request)
            headers, buffered = _read_http_upgrade(connection)
            expected = base64.b64encode(
                hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
            ).decode("ascii")
            if headers.get("sec-websocket-accept") != expected:
                raise CaptureError("Chrome rejected the DevTools WebSocket handshake")
            return cls(connection, buffered)
        except BaseException:
            connection.close()
            raise

    def _read_exact(self, size: int) -> bytes:
        while len(self._buffer) < size:
            chunk = self._connection.recv(min(65536, size - len(self._buffer)))
            if not chunk:
                raise CaptureError("Chrome closed the DevTools connection")
            self._buffer.extend(chunk)
        result = bytes(self._buffer[:size])
        del self._buffer[:size]
        return result

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        length = len(payload)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.extend((0x80 | 126, *length.to_bytes(2, "big")))
        else:
            header.extend((0x80 | 127, *length.to_bytes(8, "big")))
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self._connection.sendall(bytes(header) + mask + masked)

    def send_json(self, message: dict[str, object]) -> None:
        self._send_frame(1, json.dumps(message, separators=(",", ":")).encode("utf-8"))

    def receive_json(self) -> dict[str, object]:
        fragments = bytearray()
        while True:
            final, opcode, payload = self._read_frame()
            if opcode == 8:
                raise CaptureError("Chrome closed the DevTools WebSocket")
            if opcode == 9:
                self._send_frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode not in {0, 1}:
                raise CaptureError("Chrome sent an unsupported DevTools frame")
            fragments.extend(payload)
            if len(fragments) > MAX_DEVTOOLS_PAYLOAD_BYTES:
                raise CaptureError("Chrome DevTools message exceeds the safety limit")
            if final:
                try:
                    message = json.loads(fragments.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise CaptureError("Chrome sent malformed DevTools JSON") from error
                if not isinstance(message, dict):
                    raise CaptureError("Chrome sent a non-object DevTools response")
                return message

    def _read_frame(self) -> tuple[bool, int, bytes]:
        first, second = self._read_exact(2)
        if first & 0x70:
            raise CaptureError("Chrome sent a DevTools frame with reserved flags")
        length = second & 0x7F
        if length == 126:
            length = int.from_bytes(self._read_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._read_exact(8), "big")
        if length > MAX_DEVTOOLS_PAYLOAD_BYTES:
            raise CaptureError("Chrome DevTools frame exceeds the safety limit")
        mask = self._read_exact(4) if second & 0x80 else b""
        payload = self._read_exact(length)
        if mask:
            payload = bytes(
                value ^ mask[index % 4] for index, value in enumerate(payload)
            )
        return bool(first & 0x80), first & 0x0F, payload

    def close(self) -> None:
        try:
            self._send_frame(8, b"")
        except OSError:
            pass
        self._connection.close()


class _RawDevToolsSession:
    def __init__(self, connection: _WebSocketConnection) -> None:
        self._connection = connection
        self._next_identifier = 1

    def call(
        self, method: str, params: dict[str, object] | None = None
    ) -> dict[str, object]:
        identifier = self._next_identifier
        self._next_identifier += 1
        self._connection.send_json(
            {"id": identifier, "method": method, "params": params or {}}
        )
        while True:
            message = self._connection.receive_json()
            if message.get("id") != identifier:
                continue
            if "error" in message:
                raise CaptureError(f"Chrome DevTools command {method} failed")
            result = message.get("result", {})
            if not isinstance(result, dict):
                raise CaptureError(f"Chrome DevTools command {method} returned invalid data")
            return result


def _read_http_upgrade(connection: socket.socket) -> tuple[dict[str, str], bytes]:
    received = bytearray()
    while b"\r\n\r\n" not in received:
        chunk = connection.recv(4096)
        if not chunk:
            raise CaptureError("Chrome closed the DevTools handshake")
        received.extend(chunk)
        if len(received) > 65536:
            raise CaptureError("Chrome returned oversized DevTools headers")
    raw_headers, buffered = bytes(received).split(b"\r\n\r\n", 1)
    lines = raw_headers.decode("latin-1").split("\r\n")
    if not lines or " 101 " not in f" {lines[0]} ":
        raise CaptureError("Chrome rejected the DevTools WebSocket upgrade")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return headers, buffered


def _wait_for_devtools_port(
    profile: Path,
    process: subprocess.Popen[bytes],
    policy: CapturePolicy,
) -> int:
    port_file = profile / "DevToolsActivePort"
    deadline = time.monotonic() + policy.startup_timeout_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise CaptureError(f"Chrome exited during startup with code {process.returncode}")
        if port_file.is_file():
            try:
                return read_devtools_port(port_file)
            except CaptureError:
                pass
        time.sleep(0.2)
    raise CaptureError("Chrome DevTools did not become ready before its startup deadline")


def _target_endpoint(port: int, timeout: float) -> str:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("GET", "/json/list")
        response = connection.getresponse()
        payload = response.read(1_000_001)
        if response.status != 200 or len(payload) > 1_000_000:
            raise CaptureError("Chrome returned an invalid DevTools target list")
        targets = json.loads(payload.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CaptureError("Chrome DevTools target discovery failed") from error
    finally:
        connection.close()
    if not isinstance(targets, list):
        raise CaptureError("Chrome returned a malformed DevTools target list")
    pages = [target for target in targets if isinstance(target, dict) and target.get("type") == "page"]
    endpoint = pages[0].get("webSocketDebuggerUrl") if pages else None
    if not isinstance(endpoint, str):
        raise CaptureError("Chrome exposed no page target for screenshot capture")
    return endpoint


def _stop_browser(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if process.poll() is None:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        process.wait(timeout=10)


def capture_chart(
    browser_command: str,
    screenshot: Path,
    workspace: Path,
    runtime_root: Path,
    origin_ip: str,
    policy: CapturePolicy,
) -> None:
    profile = workspace / "profile"
    profile.mkdir()
    command = build_chrome_command(browser_command, profile, origin_ip)
    identity = prepare_browser_identity(runtime_root, workspace, profile)
    browser_environment = os.environ.copy()
    process_identity: dict[str, object] = {}
    if identity is not None:
        browser_environment.update(
            {
                "HOME": str(profile),
                "XDG_CONFIG_HOME": str(profile),
                "XDG_CACHE_HOME": str(profile),
            }
        )
        process_identity = {
            "user": identity.uid,
            "group": identity.gid,
            "extra_groups": (),
        }
    log_path = workspace / "chrome.stderr.log"
    connection: _WebSocketConnection | None = None
    with log_path.open("wb") as browser_log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=browser_log,
            start_new_session=True,
            env=browser_environment,
            **process_identity,
        )
        try:
            port = _wait_for_devtools_port(profile, process, policy)
            endpoint = _target_endpoint(port, min(5, policy.socket_timeout_seconds))
            connection = _WebSocketConnection.connect(
                endpoint, policy.socket_timeout_seconds
            )
            drive_capture(_RawDevToolsSession(connection), screenshot, policy)
        finally:
            try:
                if connection is not None:
                    connection.close()
            finally:
                _stop_browser(process)
