#!/usr/bin/env python3
"""Offline regression tests for the Terna Power BI screenshot workflow."""

from __future__ import annotations

import binascii
from dataclasses import FrozenInstanceError
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib


HOST_FETCH = Path(__file__).parents[1] / "host-fetch"
sys.path.insert(0, str(HOST_FETCH))

import load_chart_capture as capture  # noqa: E402


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def grayscale_png(width: int, height: int) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    pixels = b"".join(b"\x00" + bytes([row % 251]) * width for row in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(pixels))
        + png_chunk(b"IEND", b"")
    )


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def monotonic(self) -> float:
        return self.value

    def sleep(self, seconds: float) -> None:
        self.value += seconds


class PolicyTests(unittest.TestCase):
    def test_policy_is_immutable_and_rejects_invalid_timeouts(self) -> None:
        policy = capture.CapturePolicy()

        with self.assertRaises(FrozenInstanceError):
            policy.attempts = 4  # type: ignore[misc]
        with self.assertRaises(ValueError):
            capture.CapturePolicy(attempts=0)
        with self.assertRaises(ValueError):
            capture.CapturePolicy(render_timeout_seconds=0)

    def test_origin_must_be_a_public_ipv4_literal(self) -> None:
        self.assertEqual(capture.validate_origin_ip("93.184.216.34"), "93.184.216.34")

        for value in ("10.10.3.10", "127.0.0.1", "::1", "not-an-ip"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                capture.validate_origin_ip(value)


class ReadinessTests(unittest.TestCase):
    def test_waits_for_the_power_bi_rendered_event(self) -> None:
        clock = FakeClock()
        states = iter(
            (
                capture.ReportState(False, False, False),
                capture.ReportState(True, True, False),
                capture.ReportState(True, True, True),
            )
        )

        state = capture.wait_for_report_ready(
            lambda: next(states),
            capture.CapturePolicy(render_timeout_seconds=10, poll_interval_seconds=1),
            monotonic=clock.monotonic,
            sleeper=clock.sleep,
        )

        self.assertTrue(state.rendered)
        self.assertEqual(clock.value, 2)

    def test_visible_iframe_stability_recovers_when_rendered_event_was_missed(
        self,
    ) -> None:
        clock = FakeClock()

        state = capture.wait_for_report_ready(
            lambda: capture.ReportState(True, True, False, loaded=True),
            capture.CapturePolicy(
                render_timeout_seconds=10,
                iframe_stable_fallback_seconds=2,
                poll_interval_seconds=1,
            ),
            monotonic=clock.monotonic,
            sleeper=clock.sleep,
        )

        self.assertFalse(state.rendered)
        self.assertEqual(clock.value, 2)

    def test_visible_iframe_without_power_bi_loaded_event_is_not_accepted(self) -> None:
        clock = FakeClock()

        with self.assertRaises(capture.ReportRenderTimeout):
            capture.wait_for_report_ready(
                lambda: capture.ReportState(True, True, False),
                capture.CapturePolicy(
                    render_timeout_seconds=3,
                    iframe_stable_fallback_seconds=1,
                    poll_interval_seconds=1,
                ),
                monotonic=clock.monotonic,
                sleeper=clock.sleep,
            )

    def test_fails_fast_when_power_bi_reports_an_explicit_error(self) -> None:
        with self.assertRaisesRegex(capture.ReportRenderError, "TokenExpired"):
            capture.wait_for_report_ready(
                lambda: capture.ReportState(True, True, False, "TokenExpired"),
                capture.CapturePolicy(),
            )

    def test_reports_a_bounded_timeout_with_the_last_observed_state(self) -> None:
        clock = FakeClock()

        with self.assertRaisesRegex(
            capture.ReportRenderTimeout, "document_ready=True, iframe_ready=True"
        ):
            capture.wait_for_report_ready(
                lambda: capture.ReportState(True, True, False),
                capture.CapturePolicy(
                    render_timeout_seconds=3,
                    poll_interval_seconds=1,
                ),
                monotonic=clock.monotonic,
                sleeper=clock.sleep,
            )


class ValidationTests(unittest.TestCase):
    def test_accepts_a_structurally_valid_png_with_expected_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "chart.png"
            image.write_bytes(grayscale_png(1600, 1000))

            dimensions = capture.validate_png(
                image,
                capture.CapturePolicy(min_png_bytes=100),
            )

        self.assertEqual(dimensions, (1600, 1000))

    def test_rejects_truncated_small_and_corrupted_png_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = {
                "truncated.png": b"\x89PNG\r\n\x1a\n",
                "small.png": grayscale_png(320, 200),
                "corrupt.png": grayscale_png(1600, 1000)[:-1] + b"x",
            }
            for name, payload in cases.items():
                with self.subTest(name=name):
                    image = root / name
                    image.write_bytes(payload)
                    with self.assertRaises(capture.InvalidScreenshot):
                        capture.validate_png(
                            image,
                            capture.CapturePolicy(min_png_bytes=1),
                        )

    def test_default_quality_limit_rejects_a_highly_compressed_blank_chart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "blank-chart.png"
            image.write_bytes(grayscale_png(1600, 1000))

            with self.assertRaisesRegex(capture.InvalidScreenshot, "quality limit"):
                capture.validate_png(image)


class RetryTests(unittest.TestCase):
    def test_retries_in_fresh_workspaces_and_publishes_only_a_valid_attempt(self) -> None:
        calls: list[Path] = []
        delays: list[float] = []

        def attempt(candidate: Path, workspace: Path) -> None:
            calls.append(workspace)
            if len(calls) == 1:
                raise OSError("temporary network failure")
            candidate.write_bytes(b"valid screenshot")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "chart.png"
            capture.run_capture_attempts(
                attempt,
                output,
                root / "attempts",
                capture.CapturePolicy(attempts=3, retry_backoff_seconds=(0.25,)),
                validator=lambda path, _: self.assertEqual(
                    path.read_bytes(), b"valid screenshot"
                ),
                sleeper=delays.append,
            )

            self.assertEqual(output.read_bytes(), b"valid screenshot")

        self.assertTrue(calls[0].name.startswith("attempt-1-"))
        self.assertTrue(calls[1].name.startswith("attempt-2-"))
        self.assertEqual(delays, [0.25])

    def test_a_stale_attempt_directory_cannot_be_reused(self) -> None:
        workspaces: list[Path] = []

        def attempt(candidate: Path, workspace: Path) -> None:
            workspaces.append(workspace)
            candidate.write_bytes(b"new screenshot")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            attempts = root / "attempts"
            (attempts / "attempt-1-stale").mkdir(parents=True)
            output = root / "chart.png"

            capture.run_capture_attempts(
                attempt,
                output,
                attempts,
                capture.CapturePolicy(),
                validator=lambda *_: None,
            )

            self.assertEqual(output.read_bytes(), b"new screenshot")
            self.assertNotEqual(workspaces[0].name, "attempt-1-stale")

    def test_exhaustion_preserves_the_existing_output_and_summarizes_failures(self) -> None:
        def attempt(candidate: Path, workspace: Path) -> None:
            del candidate, workspace
            raise RuntimeError("upstream unavailable")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "chart.png"
            output.write_bytes(b"last known good")

            with self.assertRaisesRegex(
                capture.CaptureAttemptsExhausted, "3/3.*upstream unavailable"
            ):
                capture.run_capture_attempts(
                    attempt,
                    output,
                    root / "attempts",
                    capture.CapturePolicy(
                        attempts=3,
                        retry_backoff_seconds=(0, 0),
                    ),
                    validator=lambda *_: None,
                    sleeper=lambda _: None,
                )

            self.assertEqual(output.read_bytes(), b"last known good")


if __name__ == "__main__":
    unittest.main()
