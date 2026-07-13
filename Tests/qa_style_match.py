#!/usr/bin/env python3
"""Regression check: replace-text preserves the document's real font/style.

Builds a PDF using an embedded system TTF (Georgia), replaces text the way
the app does (page + rect from a click), and asserts the replacement span
kept the original family, size, and color instead of falling back to a
base-14 font.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "Engine" / "pdf_engine.py"
GEORGIA = Path("/System/Library/Fonts/Supplemental/Georgia.ttf")
GEORGIA_BOLD = Path("/System/Library/Fonts/Supplemental/Georgia Bold.ttf")


def run_engine(*args: str) -> dict:
    result = subprocess.run(
        [sys.executable, str(ENGINE), *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def main() -> int:
    import fitz

    if not GEORGIA.exists():
        print("style match skipped (Georgia.ttf not present)")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "styled.pdf"
        out = Path(tmp) / "replaced.pdf"

        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((72, 120), "Invoice Number 2041", fontname="Geo", fontfile=str(GEORGIA), fontsize=22, color=(0.1, 0.1, 0.4))
        if GEORGIA_BOLD.exists():
            page.insert_text((72, 170), "Total Due: $4,850.00", fontname="GeoB", fontfile=str(GEORGIA_BOLD), fontsize=16, color=(0.6, 0.1, 0.1))
        doc.save(str(src))
        doc.close()

        payload = run_engine(
            "replace-text",
            "--input", str(src),
            "--output", str(out),
            "--find", "2041",
            "--replace", "7788",
            "--auto-size",
            "--match-style",
            "--page", "1",
        )
        assert payload.get("ok"), f"replace-text failed: {payload}"

        doc = fitz.open(str(out))
        spans = [
            span
            for block in doc[0].get_text("dict")["blocks"]
            for line in block.get("lines", [])
            for span in line.get("spans", [])
        ]
        doc.close()

        replacement = next((s for s in spans if "7788" in s["text"]), None)
        assert replacement is not None, f"replacement span not found in {[s['text'] for s in spans]}"
        assert "georgia" in replacement["font"].lower(), (
            f"replacement font is {replacement['font']!r}, expected the original Georgia"
        )
        assert abs(replacement["size"] - 22.0) < 0.6, f"size drifted: {replacement['size']}"
        assert replacement["color"] == 0x1A1A66, f"color drifted: {hex(replacement['color'])}"

        original = next((s for s in spans if "Invoice Number" in s["text"]), None)
        assert original is not None, "surrounding text lost"
        # Replacement baseline must match the surrounding text's baseline.
        assert abs(replacement["origin"][1] - original["origin"][1]) < 0.75, (
            f"baseline drifted: {replacement['origin'][1]} vs {original['origin'][1]}"
        )

    print("style match ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
