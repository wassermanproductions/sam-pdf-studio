#!/usr/bin/env python3
"""Regression check for block moves (Sam's 2026-07-12 bug report).

Moving a block in a tight, overlapping layout must:
- leave every neighboring line intact (no clipped words like 'PRO'POSAL),
- land the text exactly at the drop point,
- keep per-line styles (bold heading stays bold, body stays regular),
- remove the text from the old location.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "Engine" / "pdf_engine.py"


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

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "layout.pdf"
        out = Path(tmp) / "moved.pdf"

        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((150, 80), "Joel Eriksson", fontname="hebo", fontsize=30)
        page.insert_text((60, 100), "A U T O N O M O U S   E X C L U S I V E   P R O P O S A L   &   Q U O T E", fontname="helv", fontsize=11, color=(0.5, 0.5, 0.5))
        page.insert_text((60, 140), "PHASE 1 - CUSTOM AI AGENT BUILD (DELUXE)", fontname="hebo", fontsize=12, color=(0.4, 0.4, 0.4))
        page.insert_text((60, 165), "Full Agent Architecture", fontname="hebo", fontsize=12)
        page.insert_text((60, 180), "Custom-built AI agent with professional-grade architecture and monitoring.", fontname="helv", fontsize=10)
        doc.save(str(src))
        doc.close()

        block_text = "Full Agent Architecture\nCustom-built AI agent with professional-grade architecture and monitoring."
        payload = run_engine(
            "move-block",
            "--input", str(src),
            "--output", str(out),
            "--page", "1",
            "--rect", "60.0,152.16,389.02,182.99",
            "--text", block_text,
            "--dest-x", "200",
            "--dest-y", "400",
            "--line-height", "15.4",
        )
        assert payload.get("ok"), f"move-block failed: {payload}"

        doc = fitz.open(str(out))
        page = doc[0]
        text = page.get_text()

        assert "Joel Eriksson" in text, "title was damaged by the move"
        assert "P R O P O S A L" in text, "letter-spaced subtitle was clipped by the move"
        assert "PHASE 1 - CUSTOM AI AGENT BUILD (DELUXE)" in text, "neighbor heading damaged"
        assert text.count("Full Agent Architecture") == 1, "moved text duplicated or lost"

        hits = page.search_for("Full Agent Architecture")
        assert hits, "moved text not found"
        assert abs(hits[0].x0 - 200) < 3 and abs(hits[0].y0 - 400) < 8, (
            f"moved text landed at ({hits[0].x0:.1f}, {hits[0].y0:.1f}), expected ~(200, 400)"
        )

        spans = {
            span["text"]: span
            for block in page.get_text("dict")["blocks"]
            for line in block.get("lines", [])
            for span in line.get("spans", [])
        }
        heading = next((s for t, s in spans.items() if "Full Agent" in t), None)
        body = next((s for t, s in spans.items() if "Custom-built" in t), None)
        assert heading and "bold" in heading["font"].lower(), "moved heading lost its bold style"
        assert body and "bold" not in body["font"].lower(), "moved body gained a bold style"
        doc.close()

        # Editing a block must keep every line's own position — a
        # right-aligned amount stays right-aligned (Sam's K-1 case).
        src2 = Path(tmp) / "columns.pdf"
        out2 = Path(tmp) / "columns-edited.pdf"
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((60, 200), "GUARANTEED PAYMENTS", fontname="helv", fontsize=10)
        page.insert_text((500, 214), "23,500.", fontname="helv", fontsize=10)
        doc.save(str(src2))
        doc.close()

        payload = run_engine(
            "replace-block",
            "--input", str(src2),
            "--output", str(out2),
            "--page", "1",
            "--rect", "60,190,545,216",
            "--text", "GUARANTEED PAYMENTS EDITED\n23,500.",
        )
        assert payload.get("ok"), f"columns edit failed: {payload}"
        doc = fitz.open(str(out2))
        hits = doc[0].search_for("23,500.")
        assert hits, "amount lost during edit"
        assert abs(hits[0].x0 - 500) < 2, f"right-aligned amount drifted to x={hits[0].x0:.1f} (was 500)"
        assert "GUARANTEED PAYMENTS EDITED" in doc[0].get_text(), "edited line missing"
        doc.close()

        # Content sharing the block's bounding box (or sitting in the drag
        # path) must survive a move completely untouched (Sam's drag-path
        # deletion report, 2026-07-12).
        src3 = Path(tmp) / "overlap.pdf"
        out3 = Path(tmp) / "overlap-moved.pdf"
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((60, 100), "Movable heading", fontname="hebo", fontsize=12)
        page.insert_text((60, 118), "movable second line", fontname="helv", fontsize=10)
        page.insert_text((300, 110), "BYSTANDER TEXT", fontname="helv", fontsize=10, color=(0.5, 0, 0))
        page.insert_text((420, 300), "PATH CONTENT", fontname="helv", fontsize=10)
        doc.save(str(src3))
        doc.close()

        # Rect deliberately spans the bystander (simulating a merged block
        # bbox); the move must only take the block's own two lines.
        payload = run_engine(
            "move-block",
            "--input", str(src3),
            "--output", str(out3),
            "--page", "1",
            "--rect", "60,90,420,125",
            "--text", "Movable heading\nmovable second line",
            "--original-text", "Movable heading\nmovable second line",
            "--dest-x", "60",
            "--dest-y", "500",
        )
        assert payload.get("ok"), f"overlap move failed: {payload}"
        doc = fitz.open(str(out3))
        text = doc[0].get_text()
        assert "BYSTANDER TEXT" in text, "content sharing the block rect was deleted by the move"
        assert "PATH CONTENT" in text, "content in the drag path was deleted"
        bystander = doc[0].search_for("BYSTANDER TEXT")
        assert bystander and abs(bystander[0].y0 - 100) < 6, "bystander text moved from its spot"
        moved = doc[0].search_for("Movable heading")
        assert moved and abs(moved[0].y0 - 500) < 8, "block did not land at destination"
        doc.close()

        # Documents damaged by earlier edits can contain IDENTICAL duplicate
        # lines. Edits must hit the copy nearest the clicked block — never a
        # far-away twin (Sam's edits-reappearing / path-deletion report).
        src4 = Path(tmp) / "dupes.pdf"
        out4 = Path(tmp) / "dupes-edited.pdf"
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((60, 100), "Duplicated heading", fontname="hebo", fontsize=12)
        page.insert_text((60, 480), "Duplicated heading", fontname="hebo", fontsize=12)
        doc.save(str(src4))
        doc.close()

        payload = run_engine(
            "replace-block",
            "--input", str(src4),
            "--output", str(out4),
            "--page", "1",
            "--rect", "60,90,180,105",
            "--text", "Edited heading",
            "--original-text", "Duplicated heading",
        )
        assert payload.get("ok"), f"duplicate edit failed: {payload}"
        doc = fitz.open(str(out4))
        top = doc[0].search_for("Edited heading")
        twin = doc[0].search_for("Duplicated heading")
        # insert_text y is the baseline; glyph tops sit ~9pt above it.
        assert top and abs(top[0].y0 - 91) < 8, f"edit did not land on the nearest copy (y={top[0].y0 if top else '-'})"
        assert twin and abs(twin[0].y0 - 471) < 8, f"the far duplicate was wrongly touched (y={twin[0].y0 if twin else '-'})"
        doc.close()

        # Upward move regression: dragging a line UP to a smaller y must land
        # it there (bottom-origin vs top-origin sign bugs make the block jump
        # the wrong way), leaving lines it passes over untouched.
        src5 = Path(tmp) / "upward.pdf"
        out5 = Path(tmp) / "upward-moved.pdf"
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((60, 500), "Mover line", fontname="helv", fontsize=12)
        page.insert_text((60, 200), "Reference line", fontname="helv", fontsize=12)
        doc.save(str(src5))
        line_bbox = None
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                if "Mover line" in "".join(span["text"] for span in line["spans"]):
                    line_bbox = line["bbox"]
        ref_before = page.search_for("Reference line")
        doc.close()
        assert line_bbox, "mover line not found in source layout"
        assert ref_before, "reference line not found in source layout"

        payload = run_engine(
            "move-block",
            "--input", str(src5),
            "--output", str(out5),
            "--page", "1",
            "--rect", f"{line_bbox[0]},{line_bbox[1]},{line_bbox[2]},{line_bbox[3]}",
            "--text", "Mover line",
            "--original-text", "Mover line",
            "--dest-x", "60",
            "--dest-y", "150",
        )
        assert payload.get("ok"), f"upward move failed: {payload}"
        doc = fitz.open(str(out5))
        moved = doc[0].search_for("Mover line")
        assert moved and abs(moved[0].y0 - 150) < 3, (
            f"upward move landed at y={moved[0].y0 if moved else '-'} (expected ~150)"
        )
        reference = doc[0].search_for("Reference line")
        assert reference and abs(reference[0].y0 - ref_before[0].y0) < 1, (
            f"reference line drifted to y={reference[0].y0 if reference else '-'} "
            f"(was {ref_before[0].y0:.1f})"
        )
        doc.close()

        # Changing an existing block's font family: replace-block with an
        # explicit --font must re-render the paragraph in that font even when
        # the text is unchanged (the per-line original-font fast path must
        # yield to the user's explicit choice).
        src6 = Path(tmp) / "fontswap.pdf"
        out6 = Path(tmp) / "fontswap-edited.pdf"
        doc = fitz.open()
        page = doc.new_page(width=612, height=792)
        page.insert_text((60, 200), "Switch my font", fontname="helv", fontsize=12)
        doc.save(str(src6))
        doc.close()

        payload = run_engine(
            "replace-block",
            "--input", str(src6),
            "--output", str(out6),
            "--page", "1",
            "--rect", "60,190,220,205",
            "--text", "Switch my font",
            "--original-text", "Switch my font",
            "--font", "Courier New",
        )
        assert payload.get("ok"), f"font swap failed: {payload}"
        doc = fitz.open(str(out6))
        spans = [
            span
            for block in doc[0].get_text("dict")["blocks"]
            for line in block.get("lines", [])
            for span in line.get("spans", [])
            if "Switch my font" in span["text"]
        ]
        assert spans, "font-swapped text not found"
        assert "courier" in spans[0]["font"].lower(), (
            f"font not switched: rendered as {spans[0]['font']}"
        )
        doc.close()

    print("block move ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
