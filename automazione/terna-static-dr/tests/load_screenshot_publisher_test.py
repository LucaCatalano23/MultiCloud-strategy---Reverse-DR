#!/usr/bin/env python3
"""Offline tests for atomic publication of the Terna load chart."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "host-fetch" / "build-load-screenshot.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("load_screenshot_builder", MODULE_PATH)
assert SPEC and SPEC.loader
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class AtomicPublisherTests(unittest.TestCase):
    def test_failed_atomic_switch_restores_the_previous_chart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            chart = output / "dr" / "load-chart"
            chart.mkdir(parents=True)
            (chart / "sentinel").write_text("last known good", encoding="utf-8")
            real_replace = builder.os.replace

            def replace(source: object, destination: object) -> None:
                source_path = Path(source)  # type: ignore[arg-type]
                destination_path = Path(destination)  # type: ignore[arg-type]
                if source_path.name.startswith(".load-chart.staging-"):
                    raise OSError("simulated filesystem interruption")
                real_replace(source_path, destination_path)

            with mock.patch.object(builder.os, "replace", side_effect=replace):
                with self.assertRaisesRegex(OSError, "filesystem interruption"):
                    builder.publish(output, None, "temporaneamente non disponibile")

            self.assertEqual(
                (chart / "sentinel").read_text(encoding="utf-8"),
                "last known good",
            )


if __name__ == "__main__":
    unittest.main()
