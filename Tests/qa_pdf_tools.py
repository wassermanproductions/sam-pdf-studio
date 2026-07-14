#!/usr/bin/env python3
"""Checks for the parity tools: symbols (fill & sign stamps),
compression, page numbers, uniform page resizing, and redline review marks."""
from __future__ import annotations

import json
import os
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
        tmp_path = Path(tmp)
        src = tmp_path / "mixed.pdf"

        doc = fitz.open()
        page = doc.new_page(width=612, height=792)  # Letter
        page.insert_text((72, 100), "Alpha page with reviewable text content", fontsize=13)
        # Big image so compression has something to shrink.
        pix = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 900, 900))
        pix.set_rect(pix.irect, (200, 60, 60))
        page.insert_image(fitz.Rect(72, 140, 540, 600), pixmap=pix)
        page2 = doc.new_page(width=595, height=842)  # A4
        page2.insert_text((72, 100), "Beta page", fontsize=13)
        doc.save(str(src))
        doc.close()

        # Symbols
        out = tmp_path / "sym.pdf"
        assert run_engine("add-symbol", "--input", str(src), "--output", str(out), "--page", "1", "--kind", "check", "--x", "300", "--y", "300").get("ok")
        with fitz.open(str(out)) as d:
            fonts = {f[3] for f in d[0].get_fonts()}
        assert any("ZapfDingbats" in (f or "") for f in fonts), f"ZapfDingbats stamp missing: {fonts}"

        # Compression
        out = tmp_path / "small.pdf"
        payload = run_engine("compress", "--input", str(src), "--output", str(out), "--quality", "small")
        assert payload.get("ok") and payload["after_bytes"] <= payload["before_bytes"], f"compress failed: {payload}"

        # Page numbers
        out = tmp_path / "nums.pdf"
        assert run_engine("add-page-numbers", "--input", str(src), "--output", str(out), "--position", "bottom-right", "--number-format", "n-of-total", "--start", "5").get("ok")
        with fitz.open(str(out)) as d:
            assert "5 of 6" in d[0].get_text(), "page number label missing"
            assert "6 of 6" in d[1].get_text(), "second page number missing"

        # Resize to uniform Letter
        out = tmp_path / "resized.pdf"
        assert run_engine("resize-pages", "--input", str(src), "--output", str(out), "--width", "612", "--height", "792").get("ok")
        with fitz.open(str(out)) as d:
            sizes = {(round(p.rect.width), round(p.rect.height)) for p in d}
            assert sizes == {(612, 792)}, f"pages not uniform: {sizes}"
            assert "Beta page" in d[1].get_text(), "content lost during resize"

        # Redline marks
        out = tmp_path / "redline.pdf"
        assert run_engine("redline", "--input", str(src), "--output", str(out), "--page", "1", "--kind", "replace", "--rects", "72,88,300,104", "--note", "tighter wording").get("ok")
        with fitz.open(str(out)) as d:
            kinds = sorted(a.type[1] for a in (d[0].annots() or []))
            assert kinds == ["Caret", "StrikeOut"], f"replace mark annots wrong: {kinds}"
            notes = [a.info.get("content", "") for a in d[0].annots()]
            assert any("tighter wording" in n for n in notes), "replacement note missing"

        out = tmp_path / "squig.pdf"
        assert run_engine("redline", "--input", str(src), "--output", str(out), "--page", "1", "--kind", "squiggly", "--rects", "72,88,300,104").get("ok")
        with fitz.open(str(out)) as d:
            kinds = [a.type[1] for a in (d[0].annots() or [])]
            assert kinds == ["Squiggly"], f"squiggly annot wrong: {kinds}"

        # Block background shading (behind content, separate from text color)
        out = tmp_path / "shaded.pdf"
        assert run_engine("block-background", "--input", str(src), "--output", str(out), "--page", "1", "--rect", "70,86,320,106", "--color", "#fff3b0").get("ok")
        with fitz.open(str(out)) as d:
            assert "Alpha page" in d[0].get_text(), "text lost under background"
            # Sample the padded strip above the text where no glyphs sit.
            pix = d[0].get_pixmap(clip=fitz.Rect(100, 83.5, 106, 85.5))
            r, g, b = pix.pixel(2, 1)
            assert r > 230 and g > 220 and b < 220, f"background shade missing: {(r, g, b)}"

        # Text color AND background applied in ONE block edit must BOTH
        # persist (Sam's report: setting background used to discard the
        # pending text-color change).
        out = tmp_path / "color-and-bg.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", "70,86,320,106", "--text", "Alpha page with reviewable text content",
            "--color", "#c0392b", "--background", "#fff3b0",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        with fitz.open(str(out)) as d:
            span = next(s for b in d[0].get_text("dict")["blocks"]
                        for l in b.get("lines", []) for s in l.get("spans", [])
                        if "Alpha page" in s["text"])
            assert span["color"] == 0xc0392b, f"text color lost when background set: {hex(span['color'])}"
            pix = d[0].get_pixmap(clip=fitz.Rect(100, 83.5, 106, 85.5))
            r, g, b = pix.pixel(2, 1)
            assert r > 230 and g > 220 and b < 220, f"background lost when color set: {(r, g, b)}"

        # Font-family change alone must apply (was a no-op / reverted).
        out = tmp_path / "font-only.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", "70,86,320,106", "--text", "Alpha page with reviewable text content",
            "--font", "Courier New",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        with fitz.open(str(out)) as d:
            span = next(s for b in d[0].get_text("dict")["blocks"]
                        for l in b.get("lines", []) for s in l.get("spans", [])
                        if "Alpha page" in s["text"])
            assert "cour" in span["font"].lower(), f"font-only change not applied: {span['font']}"

        # Alignment: center and right shift the text away from the left edge.
        def alpha_span(path: str) -> dict:
            with fitz.open(path) as d:
                return next(
                    s for b in d[0].get_text("dict")["blocks"]
                    for l in b.get("lines", []) for s in l.get("spans", [])
                    if "Alpha page" in s["text"]
                )

        wide_rect = "70,86,540,106"
        out = tmp_path / "align-left.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        left_x0 = alpha_span(str(out))["bbox"][0]

        out = tmp_path / "align-center.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--align", "center",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        center_x0 = alpha_span(str(out))["bbox"][0]
        assert center_x0 > left_x0 + 10, f"center did not shift text right: {center_x0} vs {left_x0}"

        out = tmp_path / "align-right.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--align", "right",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        right_x0 = alpha_span(str(out))["bbox"][0]
        assert right_x0 > center_x0 + 10, f"right did not shift past center: {right_x0} vs {center_x0}"

        # Italic: the span reports an italic/oblique face.
        out = tmp_path / "italic.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--italic",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        italic_font = alpha_span(str(out))["font"].lower()
        assert any(tag in italic_font for tag in ("italic", "oblique", "ital", "heit", "tiit", "coit")), \
            f"italic face not applied: {italic_font}"

        # Underline: text survives and an underline rule is drawn.
        out = tmp_path / "underline.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--underline",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        with fitz.open(str(out)) as d:
            assert "Alpha page" in d[0].get_text(), "underline lost the text"
            assert d[0].get_drawings(), "underline rule missing"

        # Any system font family (Georgia is a system TTF → file-search path).
        out = tmp_path / "georgia.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", wide_rect, "--text", "Alpha page with reviewable text content",
            "--font", "Georgia",
            "--original-text", "Alpha page with reviewable text content",
        ).get("ok")
        georgia_font = alpha_span(str(out))["font"].lower()
        assert "georgia" in georgia_font, f"Georgia font not applied: {georgia_font}"

        # Track Changes on block edit: dashed review box with original text
        out = tmp_path / "tracked.pdf"
        assert run_engine(
            "replace-block", "--input", str(src), "--output", str(out), "--page", "1",
            "--rect", "70,86,320,106", "--text", "Alpha page with reworded content",
            "--track-original", "Alpha page with reviewable text content",
        ).get("ok")
        with fitz.open(str(out)) as d:
            marks = [a for a in (d[0].annots() or []) if a.type[1] == "Square"]
            assert marks, "tracked-change box missing"
            assert "reviewable text content" in marks[0].info.get("content", ""), "original text not preserved in note"

        # Selection-level (per-word) text color: coloring ONLY the middle word
        # must recolor just that word — the others stay black (Sam's report:
        # "highlight one or two words ... changes the whole section").
        colortext = "alpha beta gamma"
        runs_src = tmp_path / "runs-src.pdf"
        rdoc = fitz.open()
        rpage = rdoc.new_page(width=612, height=792)
        rpage.insert_text((72, 300), colortext, fontsize=14)
        # Use the drawn block's own bbox as the replace rect.
        rblk = next(
            b for b in rpage.get_text("dict")["blocks"]
            if any(colortext in "".join(s["text"] for s in l["spans"]) for l in b.get("lines", []))
        )
        bx = rblk["bbox"]
        rdoc.save(str(runs_src))
        rdoc.close()

        rect_runs = f"{bx[0] - 1},{bx[1] - 1},{bx[2] + 2},{bx[3] + 2}"
        beta_start = colortext.index("beta")  # 6
        runs_json = json.dumps([{"start": beta_start, "length": len("beta"), "hex": "#d00000"}])
        out = tmp_path / "wordcolor.pdf"
        assert run_engine(
            "replace-block", "--input", str(runs_src), "--output", str(out), "--page", "1",
            "--rect", rect_runs, "--text", colortext, "--original-text", colortext,
            "--color-runs", runs_json,
        ).get("ok")
        with fitz.open(str(out)) as d:
            page = d[0]
            spans = [
                s for b in page.get_text("dict")["blocks"]
                for l in b.get("lines", []) for s in l.get("spans", [])
            ]

            def span_for(word: str) -> dict:
                return next(s for s in spans if word in s["text"])

            # PyMuPDF splits differently-colored text into separate spans.
            beta = span_for("beta")
            assert beta["color"] == 0xD00000, f"beta not recolored red: {hex(beta['color'])}"
            for word in ("alpha", "gamma"):
                s = span_for(word)
                assert s["color"] == 0x000000, f"{word} should stay black: {hex(s['color'])}"

            # Pixel proof: red only under "beta", never under alpha/gamma.
            def red_pixels(bbox) -> int:
                pix = page.get_pixmap(clip=fitz.Rect(bbox), colorspace=fitz.csRGB)
                count = 0
                for yy in range(pix.height):
                    for xx in range(pix.width):
                        r, g, bl = pix.pixel(xx, yy)
                        if r > 150 and g < 90 and bl < 90:
                            count += 1
                return count

            assert red_pixels(beta["bbox"]) > 0, "no red pixels where beta is"
            assert red_pixels(span_for("alpha")["bbox"]) == 0, "red bled into alpha"
            assert red_pixels(span_for("gamma")["bbox"]) == 0, "red bled into gamma"

        # Password protection
        out = tmp_path / "locked.pdf"
        assert run_engine("set-password", "--input", str(src), "--output", str(out), "--password", "hunter2").get("ok")
        with fitz.open(str(out)) as d:
            assert d.needs_pass, "document is not password protected"
            assert d.authenticate("hunter2"), "correct password rejected"
            assert "Alpha page" in d[0].get_text(), "content unreadable after unlock"

        # Insert new text anywhere: styled single line on a fresh one-page PDF.
        fresh = tmp_path / "fresh.pdf"
        blank = fitz.open()
        blank.new_page(width=612, height=792)
        blank.save(str(fresh))
        blank.close()

        out = tmp_path / "newtext.pdf"
        assert run_engine(
            "add-text", "--input", str(fresh), "--output", str(out),
            "--page", "1", "--x", "100", "--y", "300",
            "--text", "Styled insert", "--font", "Times New Roman",
            "--font-size", "16", "--bold", "--color", "#CC0000",
        ).get("ok")
        with fitz.open(str(out)) as d:
            page = d[0]
            assert "Styled insert" in page.get_text(), "inserted text missing"
            span = None
            for block in page.get_text("dict")["blocks"]:
                for line in block.get("lines", []):
                    for s in line.get("spans", []):
                        if "Styled" in s.get("text", ""):
                            span = s
            assert span is not None, "inserted span not found"
            font = span["font"].lower()
            assert "times" in font or "tibo" in font or "bold" in font, f"unexpected font: {span['font']}"
            color = span["color"]
            cr = ((color >> 16) & 255) / 255.0
            cg = ((color >> 8) & 255) / 255.0
            cb = (color & 255) / 255.0
            assert cr > cg and cr > cb, f"inserted text not red-dominant: {(cr, cg, cb)}"
            # --y is the TOP of the first line: baseline sits y + size*0.83 below,
            # so the span box (whose ascender metric ~= size) tops out near 300.
            assert abs(span["origin"][1] - (300 + 16 * 0.83)) <= 0.5, f"baseline off: {span['origin'][1]}"
            assert abs(span["bbox"][1] - 300) <= 4, f"text top not near 300: {span['bbox'][1]}"

        # Multi-line insert: both lines present, second below the first.
        out = tmp_path / "multiline.pdf"
        assert run_engine(
            "add-text", "--input", str(fresh), "--output", str(out),
            "--page", "1", "--x", "100", "--y", "200",
            "--text", "Line one\nLine two",
        ).get("ok")
        with fitz.open(str(out)) as d:
            page = d[0]
            text = page.get_text()
            assert "Line one" in text and "Line two" in text, "multiline text missing"
            y_first = y_second = None
            for block in page.get_text("dict")["blocks"]:
                for line in block.get("lines", []):
                    for s in line.get("spans", []):
                        if "Line one" in s.get("text", ""):
                            y_first = s["bbox"][1]
                        if "Line two" in s.get("text", ""):
                            y_second = s["bbox"][1]
            assert y_first is not None and y_second is not None, "multiline spans missing"
            assert y_second > y_first, f"second line not below first: {y_first} vs {y_second}"

        # Signature stamping: a transparent PNG placed over page text must keep
        # its alpha — the page/text shows through the see-through areas of the
        # stamp (not a black box), while the underlying text survives.
        from PIL import Image, ImageDraw

        stamp = tmp_path / "stamp.png"
        img = Image.new("RGBA", (40, 40), (0, 0, 0, 0))  # fully transparent
        ImageDraw.Draw(img).line([(0, 0), (39, 39)], fill=(0, 0, 0, 255), width=3)
        img.save(str(stamp))

        signbase = tmp_path / "signbase.pdf"
        b = fitz.open()
        p = b.new_page(width=612, height=792)
        p.insert_text((72, 120), "Underlying page text here", fontsize=13)
        b.save(str(signbase))
        b.close()

        out = tmp_path / "signed.pdf"
        assert run_engine(
            "add-image", "--input", str(signbase), "--output", str(out),
            "--image", str(stamp), "--page", "1",
            "--x", "200", "--y", "200", "--width", "40", "--height", "40",
        ).get("ok")
        with fitz.open(str(out)) as d:
            page = d[0]
            assert "Underlying page text here" in page.get_text(), "page text lost under signature stamp"
            # A transparent corner of the stamp still shows the white page.
            corner = page.get_pixmap(clip=fitz.Rect(236, 201, 240, 205))
            r, g, bl = corner.pixel(1, 1)
            assert r > 240 and g > 240 and bl > 240, f"stamp flattened alpha to a box: {(r, g, bl)}"
            # The diagonal ink actually landed (dark near the center).
            center = page.get_pixmap(clip=fitz.Rect(218, 218, 222, 222))
            rr, gg, bb = center.pixel(1, 1)
            assert rr < 120 and gg < 120 and bb < 120, f"signature ink missing: {(rr, gg, bb)}"

    print("pdf tools ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
