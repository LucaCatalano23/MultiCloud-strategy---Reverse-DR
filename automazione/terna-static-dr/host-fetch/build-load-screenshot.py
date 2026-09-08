#!/usr/bin/env python3
"""Capture the public Terna Power BI load chart as a validated PNG snapshot."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from html import escape
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from uuid import uuid4

from chrome_devtools_capture import capture_chart
from load_chart_capture import (
    CaptureError,
    CapturePolicy,
    run_capture_attempts,
    validate_origin_ip,
)


DEFAULT_POLICY = CapturePolicy()


def browser() -> str:
    configured = os.environ.get("TERNA_SCREENSHOT_BROWSER", "")
    candidates = [configured, "google-chrome", "chromium", "chromium-browser"]
    for candidate in candidates:
        if candidate and shutil.which(candidate):
            return candidate
    raise RuntimeError("No Chromium-compatible browser is installed")


def publish(output: Path, image: Path | None, message: str) -> None:
    chart = output / "dr" / "load-chart"
    chart.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".load-chart.staging-", dir=chart.parent))
    try:
        ready = image is not None
        if ready:
            shutil.copyfile(image, staging / "chart.png")
        (staging / "data.json").write_text(json.dumps({"status": "ready" if ready else "unavailable", "captured_at": datetime.now(timezone.utc).isoformat(), "message": message}) + "\n")
        body = '<img src="./chart.png" alt="Screenshot del grafico Terna del fabbisogno energetico nazionale">' if ready else f"<p>{escape(message)}</p>"
        (staging / "index.html").write_text(f'<!doctype html><meta charset="utf-8"><title>Fabbisogno nazionale - DR</title><style>body{{margin:0;font-family:Arial;color:#172b4d}}img{{display:block;width:100%;height:auto}}</style>{body}')
        (staging / (".load-chart-v1" if ready else ".load-chart-placeholder-v1")).write_text("screenshot\n")
        backup = chart.with_name(f".{chart.name}.previous-{uuid4().hex}")
        if chart.exists():
            os.replace(chart, backup)
        try:
            os.replace(staging, chart)
        except OSError:
            if backup.exists() and not chart.exists():
                os.replace(backup, chart)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--origin-ip", required=True)
    parser.add_argument("--placeholder", action="store_true")
    args = parser.parse_args()
    if args.placeholder:
        publish(args.output, None, "Screenshot del grafico temporaneamente non disponibile nella copia DR.")
        return 0
    origin_ip = validate_origin_ip(args.origin_ip)
    browser_command = browser()
    with tempfile.TemporaryDirectory(prefix="terna-chart-") as temporary:
        temporary_path = Path(temporary)
        screenshot = temporary_path / "chart.png"
        run_capture_attempts(
            lambda candidate, workspace: capture_chart(
                browser_command,
                candidate,
                workspace,
                temporary_path,
                origin_ip,
                DEFAULT_POLICY,
            ),
            screenshot,
            temporary_path / "attempts",
            DEFAULT_POLICY,
        )
        publish(args.output, screenshot, "Screenshot del grafico Terna acquisito dal primario.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CaptureError, OSError, RuntimeError, ValueError) as error:
        print(f"Terna chart screenshot unavailable: {error}", file=sys.stderr)
        raise SystemExit(1)
