#!/usr/bin/env python3
"""Build a bounded, same-origin static bundle of the Terna home page.

The source document is fetched separately by the host service.  This program
discovers its render dependencies, downloads them through a pinned origin IP,
and publishes a new directory only after validating the completed bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from html import unescape
from html.parser import HTMLParser
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
from typing import Callable, Iterable
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit


SITE_URL = "https://www.terna.it/it"
PUBLIC_LOAD_CHART_PATH = (
    "/Portals/0/Resources/sistemaelettrico/trasparencyreport/"
    "Load-Curva-di-Carico-se.html"
)
DR_LOAD_CHART_PATH = "/dr/load-chart/index.html"
ALLOWED_HOSTS = frozenset({"www.terna.it", "terna.it"})
DEFAULT_MAX_ASSETS = 750
DEFAULT_MAX_FILE_BYTES = 25 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 300 * 1024 * 1024
MIN_STYLESHEETS = 3
MIN_SCRIPTS = 1
MIN_ASSETS = 10

# This standalone component is deliberately independent of Terna's dynamic
# cards: external CMS styles cannot shrink, hide or indefinitely load it.
HOME_CHART_SECTION = f"""<section id="terna-static-dr-load-chart" aria-labelledby="terna-static-dr-load-chart-title">
  <style>
    #terna-static-dr-load-chart{{background:#f3f7fc;padding:2.5rem max(1.25rem,calc((100% - 76rem)/2));color:#142d57}}
    #terna-static-dr-load-chart .terna-static-dr-chart-shell{{max-width:76rem;margin:auto;background:#fff;border:1px solid #d7e1f0;border-radius:.5rem;padding:1.5rem;box-shadow:0 .5rem 1.5rem rgba(20,45,87,.1)}}
    #terna-static-dr-load-chart p{{margin:0 0 .5rem;color:#466080;font:600 .8rem/1.4 Arial,sans-serif;letter-spacing:.08em;text-transform:uppercase}}
    #terna-static-dr-load-chart h2{{margin:0 0 1.25rem;color:#142d57;font:700 clamp(1.7rem,3vw,2.5rem)/1.15 Arial,sans-serif}}
    #terna-static-dr-load-chart iframe{{display:block;width:100%;height:34rem;border:0;background:#fff}}
    @media(max-width:42rem){{#terna-static-dr-load-chart{{padding:1rem}}#terna-static-dr-load-chart .terna-static-dr-chart-shell{{padding:1rem}}#terna-static-dr-load-chart iframe{{height:28rem}}}}
  </style>
  <div class="terna-static-dr-chart-shell">
    <p>Copia DR · dati consolidati all'ultima acquisizione valida</p>
    <h2 id="terna-static-dr-load-chart-title">Fabbisogno energetico nazionale</h2>
    <iframe src="{DR_LOAD_CHART_PATH}" title="Grafico del fabbisogno energetico nazionale" loading="eager"></iframe>
  </div>
</section>"""

CSS_URL_RE = re.compile(r"url\(\s*(['\"]?)(.*?)\1\s*\)", re.IGNORECASE | re.DOTALL)
CSS_IMPORT_RE = re.compile(
    r"@import\s+(?:url\(\s*)?(['\"])(.*?)\1\s*\)?", re.IGNORECASE
)
JS_IMPORT_RE = re.compile(
    r"(?:\bimport\s*(?:\(\s*)?|\b(?:import|export)\s+[^;\n]*?\bfrom\s*)"
    r"(['\"])([^'\"]+)\1\s*\)?",
    re.MULTILINE,
)
INLINE_ASSET_RE = re.compile(
    r"(['\"])(/[^'\"<>]+?\."
    r"(?:avif|css|gif|ico|jpe?g|js|json|mjs|mp4|png|svg|webp|woff2?|ttf)"
    r"(?:\?[^'\"]*)?)\1",
    re.IGNORECASE,
)
QUOTED_URL_RE = re.compile(
    r"(?P<quote>['\"])(?P<url>"
    r"(?:(?:https?:)?//(?:www\.)?terna\.it|/|\.\.?/)[^'\"<>\s)]+)"
    r"(?P=quote)",
    re.IGNORECASE,
)
SRCSET_ATTR_RE = re.compile(
    r"(?P<prefix>\b(?:srcset|data-srcset)\s*=\s*)(?P<quote>['\"])(?P<value>.*?)(?P=quote)",
    re.IGNORECASE | re.DOTALL,
)


class BundleError(RuntimeError):
    """Base class for deterministic bundle failures."""


class UnsafeAssetPath(BundleError):
    """Raised when a URL could escape or ambiguously map into the output."""


class BundleLimitError(BundleError):
    """Raised when a configured resource cap is exceeded."""


class BundleValidationError(BundleError):
    """Raised when a completed candidate is too incomplete to publish."""


@dataclass
class Discovery:
    urls: set[str] = field(default_factory=set)
    stylesheets: set[str] = field(default_factory=set)
    scripts: set[str] = field(default_factory=set)


def _decoded_path_has_ambiguity(raw_path: str) -> bool:
    current = raw_path
    if "\\" in current:
        return True
    for _ in range(3):
        decoded = unquote(current)
        if decoded == current:
            return False
        if (
            "\\" in decoded
            or decoded.count("/") != current.count("/")
            or ".." in decoded.split("/")
        ):
            return True
        current = decoded
    return unquote(current) != current


def _relative_path_escapes_root(raw_path: str, base_path: str) -> bool:
    if raw_path.startswith("/"):
        segments: list[str] = []
    else:
        segments = [part for part in PurePosixPath(base_path).parent.parts if part != "/"]
    for part in raw_path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not segments:
                return True
            segments.pop()
        else:
            segments.append(part)
    return False


def normalize_asset_url(value: str, base_url: str) -> str | None:
    """Return a fragment-free same-origin HTTPS URL, or ``None`` if irrelevant."""
    raw = unescape(value).strip()
    if not raw or raw.startswith("#") or any(ord(char) < 32 for char in raw):
        return None
    parsed_raw = urlsplit(raw)
    if parsed_raw.scheme and parsed_raw.scheme.lower() not in {"http", "https"}:
        return None
    if parsed_raw.hostname and parsed_raw.hostname.lower() not in ALLOWED_HOSTS:
        return None
    if _decoded_path_has_ambiguity(parsed_raw.path):
        raise UnsafeAssetPath(f"Ambiguous asset path: {value!r}")
    base_path = urlsplit(base_url).path
    if _relative_path_escapes_root(parsed_raw.path, base_path):
        raise UnsafeAssetPath(f"Asset path escapes site root: {value!r}")

    resolved = urlsplit(urljoin(base_url, raw))
    host = (resolved.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        return None
    if resolved.port not in (None, 80, 443):
        return None
    normalized_path = resolved.path or "/"
    return urlunsplit(("https", "www.terna.it", normalized_path, resolved.query, ""))


def output_path_for_url(url: str, kind: str | None = None) -> Path:
    """Map a normalized URL path below the bundle root."""
    parsed = urlsplit(url)
    decoded_path = unquote(parsed.path)
    if _decoded_path_has_ambiguity(parsed.path):
        raise UnsafeAssetPath(f"Ambiguous output path: {url!r}")
    parts = [part for part in PurePosixPath(decoded_path).parts if part not in ("/", "")]
    if not parts or any(part in (".", "..") for part in parts):
        raise UnsafeAssetPath(f"Invalid asset output path: {url!r}")
    relative_path = Path(*parts)
    if not parsed.query:
        return relative_path

    query_hash = hashlib.sha256(parsed.query.encode("utf-8")).hexdigest()[:12]
    suffix = relative_path.suffix
    lower_name = relative_path.name.lower()
    if kind == "css" and not lower_name.endswith(".css"):
        new_name = f"{relative_path.name}.q-{query_hash}.css"
    elif kind == "js" and not lower_name.endswith((".js", ".mjs")):
        new_name = f"{relative_path.name}.q-{query_hash}.js"
    elif suffix:
        new_name = f"{relative_path.stem}.q-{query_hash}{suffix}"
    else:
        new_name = f"{relative_path.name}.q-{query_hash}"
    return relative_path.with_name(new_name)


def _normalized_many(values: Iterable[str], base_url: str) -> set[str]:
    result: set[str] = set()
    for value in values:
        normalized = normalize_asset_url(value, base_url)
        if normalized:
            result.add(normalized)
    return result


def _srcset_urls(value: str) -> Iterable[str]:
    for candidate in value.split(","):
        fields = candidate.strip().split(maxsplit=1)
        if fields:
            yield fields[0]


class _AssetHTMLParser(HTMLParser):
    def __init__(self, base_url: str) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.discovery = Discovery()
        self._inside_style = False
        self._inside_inline_script = False

    def _add(self, value: str, *, stylesheet: bool = False, script: bool = False) -> None:
        normalized = normalize_asset_url(value, self.base_url)
        if not normalized:
            return
        self.discovery.urls.add(normalized)
        if stylesheet:
            self.discovery.stylesheets.add(normalized)
        if script:
            self.discovery.scripts.add(normalized)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {name.lower(): value or "" for name, value in attrs}
        tag = tag.lower()
        if tag == "style":
            self._inside_style = True
        if tag == "link":
            rels = set(attributes.get("rel", "").lower().split())
            if rels.intersection({"stylesheet", "preload", "icon"}):
                self._add(
                    attributes.get("href", ""), stylesheet="stylesheet" in rels
                )
        elif tag == "script":
            script_source = attributes.get("src", "")
            self._add(script_source, script=True)
            self._inside_inline_script = not bool(script_source)
        elif tag in {"img", "source", "video"}:
            for attribute in ("src",):
                self._add(attributes.get(attribute, ""))
            for attribute in ("srcset",):
                for value in _srcset_urls(attributes.get(attribute, "")):
                    self._add(value)
        for attribute in ("data-src", "data-lazy-src", "poster"):
            self._add(attributes.get(attribute, ""))
        for value in _srcset_urls(attributes.get("data-srcset", "")):
            self._add(value)
        base_path = attributes.get("data-base-path", "")
        data_file = attributes.get("data-events", "")
        if base_path and data_file:
            self._add(urljoin(self.base_url, urljoin(base_path, data_file)))
        if "style" in attributes:
            self.discovery.urls.update(
                discover_css_assets(attributes["style"], self.base_url)
            )

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "style":
            self._inside_style = False
        if tag.lower() == "script":
            self._inside_inline_script = False

    def handle_data(self, data: str) -> None:
        if self._inside_style:
            self.discovery.urls.update(discover_css_assets(data, self.base_url))
        elif self._inside_inline_script:
            self.discovery.urls.update(
                _normalized_many(
                    (match.group(2) for match in INLINE_ASSET_RE.finditer(data)),
                    self.base_url,
                )
            )


def discover_html_assets(html: str, base_url: str = SITE_URL) -> Discovery:
    parser = _AssetHTMLParser(base_url)
    parser.feed(html)
    parser.close()
    return parser.discovery


def discover_css_assets(css: str, base_url: str) -> set[str]:
    values = [match.group(2) for match in CSS_URL_RE.finditer(css)]
    values.extend(match.group(2) for match in CSS_IMPORT_RE.finditer(css))
    return _normalized_many(values, base_url)


def _discover_css_imports(css: str, base_url: str) -> set[str]:
    return _normalized_many(
        (match.group(2) for match in CSS_IMPORT_RE.finditer(css)), base_url
    )


def discover_js_module_assets(javascript: str, base_url: str) -> set[str]:
    return _normalized_many(
        (match.group(2) for match in JS_IMPORT_RE.finditer(javascript)), base_url
    )


def _asset_kind(url: str, known_stylesheets: set[str], known_scripts: set[str]) -> str | None:
    if _is_stylesheet(url, known_stylesheets):
        return "css"
    if _is_javascript(url, known_scripts):
        return "js"
    return None


def _public_path_for_url(
    url: str, known_stylesheets: set[str], known_scripts: set[str]
) -> str:
    return "/" + output_path_for_url(
        url, _asset_kind(url, known_stylesheets, known_scripts)
    ).as_posix()


def _rewrite_url_value(value: str, base_url: str, public_paths: dict[str, str]) -> str:
    try:
        normalized = normalize_asset_url(value, base_url)
    except UnsafeAssetPath:
        return value
    if not normalized:
        return value
    return public_paths.get(normalized, value)


def _rewrite_srcset_value(value: str, base_url: str, public_paths: dict[str, str]) -> str:
    rewritten_candidates: list[str] = []
    for candidate in value.split(","):
        prefix = candidate[: len(candidate) - len(candidate.lstrip())]
        fields = candidate.strip().split(maxsplit=1)
        if not fields:
            rewritten_candidates.append(candidate)
            continue
        fields[0] = _rewrite_url_value(fields[0], base_url, public_paths)
        rewritten_candidates.append(prefix + " ".join(fields))
    return ",".join(rewritten_candidates)


def rewrite_same_origin_references(
    text: str, base_url: str, public_paths: dict[str, str]
) -> str:
    """Rewrite captured Terna asset references to their local bundle paths."""

    def replace_srcset(match: re.Match[str]) -> str:
        value = _rewrite_srcset_value(match.group("value"), base_url, public_paths)
        return f"{match.group('prefix')}{match.group('quote')}{value}{match.group('quote')}"

    def replace_css_url(match: re.Match[str]) -> str:
        quote = match.group(1) or ""
        value = match.group(2).strip()
        rewritten = _rewrite_url_value(value, base_url, public_paths)
        return f"url({quote}{rewritten}{quote})"

    def replace_quoted_url(match: re.Match[str]) -> str:
        rewritten = _rewrite_url_value(match.group("url"), base_url, public_paths)
        return f"{match.group('quote')}{rewritten}{match.group('quote')}"

    rewritten = SRCSET_ATTR_RE.sub(replace_srcset, text)
    rewritten = CSS_URL_RE.sub(replace_css_url, rewritten)
    return QUOTED_URL_RE.sub(replace_quoted_url, rewritten)


class CurlFetcher:
    """Fetch same-origin assets while pinning both Terna hostnames to one IP."""

    def __init__(self, origin_ip: str, max_file_bytes: int = DEFAULT_MAX_FILE_BYTES):
        address = ipaddress.ip_address(origin_ip)
        if address.version != 4 or not address.is_global:
            raise ValueError("--origin-ip must be a public IPv4 address")
        self.origin_ip = origin_ip
        self.max_file_bytes = max_file_bytes

    def __call__(self, url: str) -> bytes:
        normalized = normalize_asset_url(url, SITE_URL)
        if normalized != url:
            raise UnsafeAssetPath(f"Fetcher received a non-normalized URL: {url!r}")
        with tempfile.NamedTemporaryFile() as downloaded:
            command = [
                "curl", "--fail", "--silent", "--show-error",
                "--compressed", "--retry", "2", "--retry-all-errors",
                "--connect-timeout", "15", "--max-time", "90",
                "--max-filesize", str(self.max_file_bytes), "--noproxy", "*",
                "--proto", "=https", "--proto-redir", "=https",
                "--resolve", f"www.terna.it:443:{self.origin_ip}",
                "--resolve", f"terna.it:443:{self.origin_ip}",
                "--user-agent",
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "Chrome/140.0.0.0 Safari/537.36",
                "--header", "Accept-Language: it-IT,it;q=0.9",
                "--output", downloaded.name, "--write-out", "%{url_effective}", url,
            ]
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            effective = normalize_asset_url(result.stdout.strip(), SITE_URL)
            if not effective:
                raise BundleError(f"Asset redirected outside terna.it: {url}")
            downloaded.seek(0)
            payload = downloaded.read(self.max_file_bytes + 1)
        if len(payload) > self.max_file_bytes:
            raise BundleLimitError(f"Asset exceeds file-size cap: {url}")
        return payload


def _is_stylesheet(url: str, known_stylesheets: set[str]) -> bool:
    return url in known_stylesheets or urlsplit(url).path.lower().endswith(".css")


def _is_javascript(url: str, known_scripts: set[str]) -> bool:
    suffix = urlsplit(url).path.lower()
    return url in known_scripts or suffix.endswith((".js", ".mjs"))


def _publish_directory(staging: Path, output: Path) -> None:
    backup = output.with_name(f".{output.name}.previous-{os.getpid()}")
    had_previous = output.exists()
    if had_previous:
        if output.is_symlink() or not output.is_dir():
            raise BundleError(f"Output must be a real directory: {output}")
        os.replace(output, backup)
    try:
        os.replace(staging, output)
    except BaseException:
        if had_previous and backup.exists():
            os.replace(backup, output)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def build_bundle(
    source: Path,
    output: Path,
    origin_ip: str,
    fetch: Callable[[str], bytes] | None = None,
    *,
    max_assets: int = DEFAULT_MAX_ASSETS,
    max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
    max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES,
) -> dict[str, object]:
    """Build and atomically publish a validated static asset bundle."""
    address = ipaddress.ip_address(origin_ip)
    if address.version != 4 or not address.is_global:
        raise ValueError("--origin-ip must be a public IPv4 address")
    original_source_bytes = source.read_bytes()
    if len(original_source_bytes) > max_file_bytes:
        raise BundleLimitError("Source HTML exceeds file-size cap")
    html = original_source_bytes.decode("utf-8", errors="replace")
    load_chart_references = html.count(PUBLIC_LOAD_CHART_PATH)
    if load_chart_references < 1:
        raise BundleValidationError(
            "Terna homepage no longer contains the expected load-chart reference"
        )
    # The DR endpoint is HTTP in the isolated lab. Keep all first-party links
    # and runtime requests on the current origin instead of forcing HTTPS back
    # to the public site (or to an ingress without a matching certificate).
    html = html.replace("https://www.terna.it", "").replace("https://terna.it", "")
    html = html.replace(PUBLIC_LOAD_CHART_PATH, DR_LOAD_CHART_PATH)
    dr_style = '<style id="terna-static-dr">.cms-panel{display:none!important}</style>'
    if re.search(r"</head\s*>", html, flags=re.IGNORECASE):
        html = re.sub(r"</head\s*>", dr_style + "</head>", html, count=1, flags=re.IGNORECASE)
    else:
        html = dr_style + html
    body_opening = re.search(r"<body(?:\s[^>]*)?>", html, flags=re.IGNORECASE)
    if body_opening:
        html = (
            html[: body_opening.end()]
            + HOME_CHART_SECTION
            + html[body_opening.end() :]
        )
    else:
        html = HOME_CHART_SECTION + html
    source_bytes = html.encode("utf-8")
    initial = discover_html_assets(html, SITE_URL)
    fetch_asset = fetch or CurlFetcher(origin_ip, max_file_bytes)

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent))
    queued = list(sorted(initial.urls))
    queued_set = set(queued)
    downloaded: dict[str, dict[str, object]] = {}
    claimed_paths: dict[Path, str] = {}
    stylesheets = set(initial.stylesheets)
    scripts = set(initial.scripts)
    total_bytes = len(source_bytes)
    try:
        while queued:
            if len(queued_set) > max_assets:
                raise BundleLimitError(f"Asset-count cap exceeded ({max_assets})")
            url = queued.pop(0)
            payload = fetch_asset(url)
            if len(payload) > max_file_bytes:
                raise BundleLimitError(f"Asset exceeds file-size cap: {url}")
            total_bytes += len(payload)
            if total_bytes > max_total_bytes:
                raise BundleLimitError("Bundle total-size cap exceeded")

            relative_path = output_path_for_url(url, _asset_kind(url, stylesheets, scripts))
            previous_url = claimed_paths.get(relative_path)
            if previous_url and previous_url != url:
                raise BundleValidationError(
                    f"Two URLs map to the same output path: {previous_url} and {url}"
                )
            claimed_paths[relative_path] = url
            destination = staging / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
            downloaded[url] = {
                "path": relative_path.as_posix(),
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }

            discovered: set[str] = set()
            text = payload.decode("utf-8", errors="replace")
            if _is_stylesheet(url, stylesheets):
                stylesheets.add(url)
                discovered = discover_css_assets(text, url)
                stylesheets.update(_discover_css_imports(text, url))
            elif _is_javascript(url, scripts):
                scripts.add(url)
                discovered = discover_js_module_assets(text, url)
                scripts.update(discovered)
            for child in sorted(discovered):
                if child not in queued_set:
                    queued_set.add(child)
                    queued.append(child)

        if len(stylesheets.intersection(downloaded)) < MIN_STYLESHEETS:
            raise BundleValidationError(
                f"Bundle has fewer than {MIN_STYLESHEETS} stylesheets"
            )
        if len(scripts.intersection(downloaded)) < MIN_SCRIPTS:
            raise BundleValidationError(
                f"Bundle has fewer than {MIN_SCRIPTS} scripts"
            )
        if len(downloaded) < MIN_ASSETS:
            raise BundleValidationError(f"Bundle has fewer than {MIN_ASSETS} assets")

        public_paths = {
            url: _public_path_for_url(url, stylesheets, scripts) for url in downloaded
        }
        for url, details in downloaded.items():
            if not (_is_stylesheet(url, stylesheets) or _is_javascript(url, scripts)):
                continue
            relative_path = Path(str(details["path"]))
            asset_file = staging / relative_path
            rewritten = rewrite_same_origin_references(
                asset_file.read_text(encoding="utf-8", errors="replace"),
                url,
                public_paths,
            ).encode("utf-8")
            asset_file.write_bytes(rewritten)
            details["bytes"] = len(rewritten)
            details["sha256"] = hashlib.sha256(rewritten).hexdigest()

        published_html = rewrite_same_origin_references(html, SITE_URL, public_paths).encode(
            "utf-8"
        )
        (staging / "index.html").write_bytes(published_html)
        total_bytes = len(published_html) + sum(
            int(details["bytes"]) for details in downloaded.values()
        )
        if total_bytes > max_total_bytes:
            raise BundleLimitError("Bundle total-size cap exceeded after rewriting")
        manifest: dict[str, object] = {
            "version": 1,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "source_url": SITE_URL,
            "origin_ip": origin_ip,
            "stylesheet_count": len(stylesheets.intersection(downloaded)),
            "script_count": len(scripts.intersection(downloaded)),
            "asset_count": len(downloaded),
            "total_bytes": total_bytes,
            "load_chart_references": load_chart_references,
            "assets": downloaded,
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        (staging / ".bundle-v1").write_text("bundle-v1\n", encoding="ascii")
        _publish_directory(staging, output)
        return manifest
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--origin-ip", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_args()
    try:
        manifest = build_bundle(arguments.source, arguments.output, arguments.origin_ip)
    except (BundleError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Static bundle build failed: {error}", file=os.sys.stderr)
        return 1
    print(
        f"Static bundle ready: {manifest['asset_count']} assets, "
        f"{manifest['total_bytes']} bytes."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
