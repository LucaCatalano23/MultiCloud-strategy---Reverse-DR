#!/usr/bin/env python3
"""Riallinea la copia on-prem della function alla sorgente unica.

`lambda-dr` monta il codice della function da un ConfigMap versionato, mentre il
sito primario la riceve come immagine container. Le due copie devono essere lo
stesso identico codice, altrimenti la PoC dimostrerebbe due function diverse
invece della stessa function su due runtime.

Kustomize non puo' generare il ConfigMap da un file fuori dalla propria root,
quindi la copia inline resta necessaria: questo script la rigenera e
`automazione/tests/deployment-contract.ps1` verifica che sia allineata.

Uso:
    python sync-onprem-configmap.py [--check]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


HANDLER = Path(__file__).resolve().parent / "handler.py"
MANIFEST = (
    Path(__file__).resolve().parents[3]
    / "lambda-dr"
    / "kubernetes"
    / "helpdesk-ticket-processor.yaml"
)
BEGIN = "  handler.py: |\n"
INDENT = "    "


def render_block(source: str) -> str:
    lines = [f"{INDENT}{line}".rstrip() + "\n" if line.strip() else "\n" for line in source.splitlines()]
    return BEGIN + "".join(lines)


def replace_block(manifest: str, block: str) -> str:
    start = manifest.index(BEGIN)
    end = manifest.index("---", start)
    return manifest[:start] + block + manifest[end:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verifica senza scrivere")
    args = parser.parse_args()

    manifest = MANIFEST.read_text(encoding="utf-8")
    updated = replace_block(manifest, render_block(HANDLER.read_text(encoding="utf-8")))

    if manifest == updated:
        print("ConfigMap on-prem allineato alla sorgente della function.")
        return 0
    if args.check:
        print(
            "ConfigMap on-prem NON allineato a handler.py: esegui "
            "`python automazione/apps/functions/ticket-processor/sync-onprem-configmap.py`.",
            file=sys.stderr,
        )
        return 1

    MANIFEST.write_text(updated, encoding="utf-8")
    print(f"Aggiornato {MANIFEST}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
