#!/usr/bin/env python3
"""Offline tests for the Terna static bundle builder."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "host-fetch" / "build-static-bundle.py"
SPEC = importlib.util.spec_from_file_location("static_bundle_builder", MODULE_PATH)
assert SPEC and SPEC.loader
bundle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bundle
SPEC.loader.exec_module(bundle)


class DiscoveryTests(unittest.TestCase):
    def test_html_discovers_assets_but_not_anchor_pages(self) -> None:
        html = """
        <html><head>
          <link rel="stylesheet" href="/css/main.css?v=7">
          <link rel="preload" href="/fonts/site.woff2" as="font">
          <link rel="icon" href="/favicon.ico">
          <link rel="canonical" href="/it/ignored">
          <style>.hero { background: url('/img/hero.jpg') }</style>
        </head><body style="background:url(/img/body.png)">
          <a href="/it/news">Do not crawl</a>
          <script src="/js/app.js"></script>
          <img src="/img/logo.svg" data-src="/img/lazy.webp"
               srcset="/img/small.jpg 480w, /img/large.jpg 960w">
          <source src="/video/clip.mp4" data-lazy-src="/img/source.webp">
          <video poster="/img/poster.jpg"></video>
          <div data-src="/img/component.webp"></div>
          <div data-base-path="/widgets/calendar/" data-events="events-it.json"></div>
          <script>window.payload = {"image":"/img/from-inline.jpg?v=2"};</script>
        </body></html>
        """

        result = bundle.discover_html_assets(html, "https://www.terna.it/it")

        self.assertIn("https://www.terna.it/css/main.css?v=7", result.urls)
        self.assertIn("https://www.terna.it/img/hero.jpg", result.urls)
        self.assertIn("https://www.terna.it/img/large.jpg", result.urls)
        self.assertIn("https://www.terna.it/img/poster.jpg", result.urls)
        self.assertIn("https://www.terna.it/img/component.webp", result.urls)
        self.assertIn("https://www.terna.it/widgets/calendar/events-it.json", result.urls)
        self.assertIn("https://www.terna.it/img/from-inline.jpg?v=2", result.urls)
        self.assertNotIn("https://www.terna.it/it/news", result.urls)
        self.assertNotIn("https://www.terna.it/it/ignored", result.urls)
        self.assertEqual(result.stylesheets, {"https://www.terna.it/css/main.css?v=7"})

    def test_css_and_javascript_discovery_is_recursive_ready(self) -> None:
        css = """
          @import url('./theme.css?v=2');
          @import "../fonts/fonts.css" screen;
          .logo { background-image: url(../img/logo.svg#mark); }
          .inline { background: url(data:image/png;base64,AAAA); }
        """
        js = """
          import './chunk.js';
          import { named } from './named.js';
          export { value } from "../shared/value.js?v=4";
          const lazy = import('/js/lazy.js');
          const ignored = require('/js/commonjs.js');
        """

        css_urls = bundle.discover_css_assets(css, "https://www.terna.it/css/main.css")
        js_urls = bundle.discover_js_module_assets(js, "https://www.terna.it/js/app.js")

        self.assertEqual(
            css_urls,
            {
                "https://www.terna.it/css/theme.css?v=2",
                "https://www.terna.it/fonts/fonts.css",
                "https://www.terna.it/img/logo.svg",
            },
        )
        self.assertEqual(
            js_urls,
            {
                "https://www.terna.it/js/chunk.js",
                "https://www.terna.it/js/named.js",
                "https://www.terna.it/shared/value.js?v=4",
                "https://www.terna.it/js/lazy.js",
            },
        )


class UrlSafetyTests(unittest.TestCase):
    def test_same_origin_urls_preserve_query_and_strip_fragment(self) -> None:
        normalized = bundle.normalize_asset_url(
            "../assets/site.css?v=2026#ignored",
            "https://www.terna.it/it/page/",
        )
        self.assertEqual(normalized, "https://www.terna.it/it/assets/site.css?v=2026")
        self.assertEqual(
            bundle.output_path_for_url(normalized, "css"),
            Path("it/assets/site.q-17123dfeb610.css"),
        )
        self.assertEqual(
            bundle.normalize_asset_url(
                "//terna.it/media/logo.svg?x=1", "https://www.terna.it/it"
            ),
            "https://www.terna.it/media/logo.svg?x=1",
        )

    def test_external_and_non_http_resources_are_ignored(self) -> None:
        for value in (
            "https://cdn.example.net/a.css",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "mailto:test@example.com",
            "#fragment",
        ):
            with self.subTest(value=value):
                self.assertIsNone(
                    bundle.normalize_asset_url(value, "https://www.terna.it/it")
                )

    def test_traversal_and_ambiguous_paths_are_rejected(self) -> None:
        for value in (
            "../../../../etc/passwd",
            "/img/%2e%2e/secret",
            "/img/%2Fetc/passwd",
            "/img/..\\secret",
            "/img/%5c..%5csecret",
            "/img/%252e%252e/secret",
        ):
            with self.subTest(value=value):
                with self.assertRaises(bundle.UnsafeAssetPath):
                    bundle.normalize_asset_url(value, "https://www.terna.it/it/page/")

    def test_curl_fetcher_pins_both_terna_hosts(self) -> None:
        completed = mock.Mock(stdout="https://www.terna.it/css/main.css")
        with mock.patch.object(bundle.subprocess, "run", return_value=completed) as run:
            payload = bundle.CurlFetcher("93.184.216.34")(
                "https://www.terna.it/css/main.css"
            )

        command = run.call_args.args[0]
        self.assertEqual(payload, b"")
        self.assertIn("www.terna.it:443:93.184.216.34", command)
        self.assertIn("terna.it:443:93.184.216.34", command)
        self.assertIn("--max-filesize", command)

    def test_private_origin_ip_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            bundle.CurlFetcher("10.10.3.10")


class BuildTests(unittest.TestCase):
    def test_build_fetches_recursive_assets_and_publishes_only_when_valid(self) -> None:
        source_html = """
        <html><head>
          <link rel="stylesheet" href="/css/a.css?v=1">
          <link rel="stylesheet" href="/css/b.css">
          <link rel="stylesheet" href="/css/c.css">
          <script type="module" src="/js/app.js"></script>
        </head><body>
          <script>window.baseSiteUrl = "https://www.terna.it";</script>
          <script>window.card = {"iframe_url":"/Portals/0/Resources/sistemaelettrico/trasparencyreport/Load-Curva-di-Carico-se.html"};</script>
          <img src="/img/1.png"><img src="/img/2.png">
          <img src="/img/3.png"><img src="/img/4.png">
          <img src="/img/5.png"><img src="/img/6.png">
        </body></html>
        """
        payloads = {
            "https://www.terna.it/css/a.css?v=1": (
                b"@import './nested.css'; .a{background:url('/img/a.png')}"
            ),
            "https://www.terna.it/css/b.css": b".b{background:url('/img/b.png')}",
            "https://www.terna.it/css/c.css": b".c{color:#000}",
            "https://www.terna.it/css/nested.css": b".nested{color:#fff}",
            "https://www.terna.it/js/app.js": b"import './chunk.js';",
            "https://www.terna.it/js/chunk.js": b"export const ok = true;",
            **{
                f"https://www.terna.it/img/{index}.png": f"image-{index}".encode()
                for index in range(1, 7)
            },
            "https://www.terna.it/img/a.png": b"image-a",
            "https://www.terna.it/img/b.png": b"image-b",
        }
        fetched: list[str] = []

        def fake_fetch(url: str) -> bytes:
            fetched.append(url)
            return payloads[url]

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.html"
            output = root / "bundle"
            source.write_text(source_html, encoding="utf-8")

            manifest = bundle.build_bundle(source, output, "93.184.216.34", fake_fetch)

            self.assertTrue((output / "index.html").is_file())
            self.assertNotIn(
                "https://www.terna.it",
                (output / "index.html").read_text(encoding="utf-8"),
            )
            self.assertIn(
                ".cms-panel{display:none!important}",
                (output / "index.html").read_text(encoding="utf-8"),
            )
            self.assertIn(
                '"iframe_url":"/dr/load-chart/index.html"',
                (output / "index.html").read_text(encoding="utf-8"),
            )
            self.assertIn(
                'id="terna-static-dr-load-chart"',
                (output / "index.html").read_text(encoding="utf-8"),
            )
            self.assertIn(
                '<iframe src="/dr/load-chart/index.html"',
                (output / "index.html").read_text(encoding="utf-8"),
            )
            self.assertTrue((output / ".bundle-v1").is_file())
            self.assertEqual(len(list((output / "css").glob("a.q-*.css"))), 1)
            self.assertTrue((output / "css" / "nested.css").is_file())
            self.assertTrue((output / "js" / "chunk.js").is_file())
            self.assertEqual(len(fetched), len(set(fetched)))
            self.assertGreaterEqual(manifest["asset_count"], 10)
            self.assertEqual(manifest["stylesheet_count"], 4)
            self.assertEqual(manifest["script_count"], 2)
            stored = json.loads((output / "manifest.json").read_text())
            self.assertEqual(stored["origin_ip"], "93.184.216.34")
            self.assertEqual(stored["asset_count"], manifest["asset_count"])

    def test_build_rewrites_query_distinct_assets_without_path_collision(self) -> None:
        source_html = """
        <html><head>
          <link rel="stylesheet" href="/DependencyHandler.axd?v=css-a">
          <link rel="stylesheet" href="/DependencyHandler.axd?v=css-b">
          <link rel="stylesheet" href="/css/c.css">
          <script type="module" src="/DependencyHandler.axd?v=js-a"></script>
        </head><body>
          <script>window.card = {"iframe_url":"/Portals/0/Resources/sistemaelettrico/trasparencyreport/Load-Curva-di-Carico-se.html"};</script>
          <img src="/img/1.png?version=1">
          <img src="/img/1.png?version=2">
          <img src="/img/2.png"><img src="/img/3.png"><img src="/img/4.png">
          <img src="/img/5.png"><img src="/img/6.png">
        </body></html>
        """
        payloads = {
            "https://www.terna.it/DependencyHandler.axd?v=css-a": (
                b".a{background:url('/img/background.png?skin=a')}"
            ),
            "https://www.terna.it/DependencyHandler.axd?v=css-b": b".b{color:#111}",
            "https://www.terna.it/css/c.css": b".c{color:#222}",
            "https://www.terna.it/DependencyHandler.axd?v=js-a": (
                b"import '/js/chunk.js?v=1';"
            ),
            "https://www.terna.it/js/chunk.js?v=1": b"export const ok = true;",
            "https://www.terna.it/img/1.png?version=1": b"image-v1",
            "https://www.terna.it/img/1.png?version=2": b"image-v2",
            "https://www.terna.it/img/background.png?skin=a": b"background",
            **{
                f"https://www.terna.it/img/{index}.png": f"image-{index}".encode()
                for index in range(2, 7)
            },
        }

        def fake_fetch(url: str) -> bytes:
            return payloads[url]

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.html"
            output = root / "bundle"
            source.write_text(source_html, encoding="utf-8")

            manifest = bundle.build_bundle(source, output, "93.184.216.34", fake_fetch)

            html = (output / "index.html").read_text(encoding="utf-8")
            self.assertNotIn("/DependencyHandler.axd?v=css-a", html)
            self.assertIn("/DependencyHandler.axd.q-", html)
            self.assertIn(".css", html)
            self.assertNotIn("/img/1.png?version=1", html)
            self.assertTrue((output / "img").is_dir())
            self.assertEqual(
                len(list((output / "img").glob("1.q-*.png"))),
                2,
            )
            css_files = list(output.glob("DependencyHandler.axd.q-*.css"))
            self.assertEqual(len(css_files), 2)
            css_content = css_files[0].read_text(encoding="utf-8") + css_files[
                1
            ].read_text(encoding="utf-8")
            self.assertNotIn("/img/background.png?skin=a", css_content)
            self.assertGreaterEqual(manifest["asset_count"], 10)

    def test_build_rejects_a_homepage_without_the_expected_load_chart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.html"
            output = root / "bundle"
            source.write_text("<html><body>Terna</body></html>", encoding="utf-8")

            with self.assertRaisesRegex(
                bundle.BundleValidationError, "load-chart reference"
            ):
                bundle.build_bundle(
                    source, output, "93.184.216.34", lambda _: b"unused"
                )

            self.assertFalse(output.exists())

    def test_invalid_bundle_does_not_replace_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.html"
            output = root / "bundle"
            output.mkdir()
            (output / "sentinel").write_text("previous", encoding="utf-8")
            source.write_text(
                '<html><link rel="stylesheet" href="/only.css"></html>',
                encoding="utf-8",
            )

            with self.assertRaises(bundle.BundleValidationError):
                bundle.build_bundle(source, output, "93.184.216.34", lambda _: b"x")

            self.assertEqual((output / "sentinel").read_text(), "previous")
            self.assertFalse((output / "index.html").exists())


if __name__ == "__main__":
    unittest.main()
