#!/usr/bin/env python3
"""Application rules for reliable Terna Power BI screenshot acquisition."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import ipaddress
import os
from pathlib import Path
import struct
import tempfile
import time
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_CHUNK_BYTES = 64 * 1024 * 1024


class CaptureError(RuntimeError):
    """Base class for expected screenshot acquisition failures."""


class ReportRenderError(CaptureError):
    """Power BI explicitly reported that the report could not be rendered."""


class ReportRenderTimeout(CaptureError):
    """Power BI did not emit its rendered event within the bounded wait."""


class InvalidScreenshot(CaptureError):
    """The acquired file is not a complete, sufficiently large PNG."""


class CaptureAttemptsExhausted(CaptureError):
    """Every isolated screenshot attempt failed."""


@dataclass(frozen=True)
class CapturePolicy:
    attempts: int = 3
    startup_timeout_seconds: float = 30
    render_timeout_seconds: float = 150
    socket_timeout_seconds: float = 45
    poll_interval_seconds: float = 1
    iframe_stable_fallback_seconds: float = 30
    settle_seconds: float = 3
    retry_backoff_seconds: tuple[float, ...] = (2, 5)
    min_png_bytes: int = 20_000
    min_width: int = 1_200
    min_height: int = 700

    def __post_init__(self) -> None:
        positive_values = (
            self.attempts,
            self.startup_timeout_seconds,
            self.render_timeout_seconds,
            self.socket_timeout_seconds,
            self.poll_interval_seconds,
            self.iframe_stable_fallback_seconds,
            self.min_png_bytes,
            self.min_width,
            self.min_height,
        )
        if any(value <= 0 for value in positive_values):
            raise ValueError("Capture policy limits must be positive")
        if self.settle_seconds < 0 or any(
            delay < 0 for delay in self.retry_backoff_seconds
        ):
            raise ValueError("Capture policy delays cannot be negative")
        if self.attempts > 1 and not self.retry_backoff_seconds:
            raise ValueError("Retry delays are required when attempts is greater than one")


@dataclass(frozen=True)
class ReportState:
    document_ready: bool
    iframe_ready: bool
    rendered: bool
    error: str | None = None
    loaded: bool = False

    def diagnostic(self) -> str:
        return (
            f"document_ready={self.document_ready}, "
            f"iframe_ready={self.iframe_ready}, loaded={self.loaded}, "
            f"rendered={self.rendered}"
        )


def validate_origin_ip(origin_ip: str) -> str:
    """Accept only a public IPv4 literal for Chromium's resolver pinning."""
    try:
        address = ipaddress.ip_address(origin_ip)
    except ValueError as error:
        raise ValueError("Terna origin must be an IPv4 literal") from error
    if address.version != 4 or not address.is_global:
        raise ValueError("Terna origin must be a public IPv4 address")
    return str(address)


def wait_for_report_ready(
    probe: Callable[[], ReportState],
    policy: CapturePolicy,
    *,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> ReportState:
    """Wait for Power BI's semantic rendered event rather than a fixed delay."""
    deadline = monotonic() + policy.render_timeout_seconds
    last_state = ReportState(False, False, False)
    iframe_ready_since: float | None = None
    while True:
        last_state = probe()
        observed_at = monotonic()
        if last_state.error:
            raise ReportRenderError(f"Power BI render failed: {last_state.error}")
        if last_state.document_ready and last_state.iframe_ready and last_state.rendered:
            return last_state
        if last_state.document_ready and last_state.iframe_ready and last_state.loaded:
            if iframe_ready_since is None:
                iframe_ready_since = observed_at
            elif (
                observed_at - iframe_ready_since
                >= policy.iframe_stable_fallback_seconds
            ):
                return last_state
        else:
            iframe_ready_since = None
        if observed_at >= deadline:
            raise ReportRenderTimeout(
                "Power BI render deadline exceeded; last state: "
                + last_state.diagnostic()
            )
        sleeper(policy.poll_interval_seconds)


def _read_png_chunks(payload: bytes) -> tuple[int, int]:
    offset = len(PNG_SIGNATURE)
    dimensions: tuple[int, int] | None = None
    saw_image_data = False
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise InvalidScreenshot("PNG contains a truncated chunk")
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        if length > MAX_PNG_CHUNK_BYTES:
            raise InvalidScreenshot("PNG chunk exceeds the safety limit")
        kind = payload[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(payload):
            raise InvalidScreenshot("PNG contains incomplete chunk data")
        data = payload[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", payload[end - 4 : end])[0]
        if zlib.crc32(kind + data) & 0xFFFFFFFF != expected_crc:
            raise InvalidScreenshot("PNG chunk checksum is invalid")
        if kind == b"IHDR" and offset == len(PNG_SIGNATURE) and length == 13:
            dimensions = struct.unpack(">II", data[:8])
        elif kind == b"IDAT":
            saw_image_data = True
        elif kind == b"IEND":
            if length != 0 or end != len(payload):
                raise InvalidScreenshot("PNG has an invalid end marker")
            if dimensions is None or not saw_image_data:
                raise InvalidScreenshot("PNG is missing required image chunks")
            return dimensions
        offset = end
    raise InvalidScreenshot("PNG is missing its end marker")


def validate_png(
    image: Path,
    policy: CapturePolicy = CapturePolicy(),
) -> tuple[int, int]:
    if not image.is_file() or image.stat().st_size < policy.min_png_bytes:
        raise InvalidScreenshot("Screenshot is missing or smaller than the quality limit")
    payload = image.read_bytes()
    if not payload.startswith(PNG_SIGNATURE):
        raise InvalidScreenshot("Screenshot does not have a PNG signature")
    width, height = _read_png_chunks(payload)
    if width < policy.min_width or height < policy.min_height:
        raise InvalidScreenshot(
            f"Screenshot dimensions {width}x{height} are below the quality limit"
        )
    return width, height


def _failure_summary(attempt: int, error: Exception) -> str:
    detail = " ".join(str(error).split()) or "no diagnostic detail"
    return f"{attempt}: {type(error).__name__}: {detail[:300]}"


def run_capture_attempts(
    capture_attempt: Callable[[Path, Path], None],
    output: Path,
    workspace: Path,
    policy: CapturePolicy = CapturePolicy(),
    *,
    validator: Callable[[Path, CapturePolicy], object] = validate_png,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    """Run isolated retries and replace output only after complete validation."""
    workspace.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    for attempt in range(1, policy.attempts + 1):
        attempt_workspace = Path(
            tempfile.mkdtemp(prefix=f"attempt-{attempt}-", dir=workspace)
        )
        candidate = attempt_workspace / "chart.png"
        try:
            capture_attempt(candidate, attempt_workspace)
            validator(candidate, policy)
            output.parent.mkdir(parents=True, exist_ok=True)
            os.replace(candidate, output)
            return
        except Exception as error:  # noqa: BLE001 - retry boundary excludes BaseException
            failures.append(_failure_summary(attempt, error))
        if attempt < policy.attempts:
            delay_index = min(attempt - 1, len(policy.retry_backoff_seconds) - 1)
            sleeper(policy.retry_backoff_seconds[delay_index])
    details = "; ".join(failures)
    raise CaptureAttemptsExhausted(
        f"Screenshot acquisition failed after {policy.attempts}/{policy.attempts} "
        f"attempts: {details}"
    )
