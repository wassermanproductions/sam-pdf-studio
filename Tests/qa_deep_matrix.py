#!/usr/bin/env python3
"""Deep QA campaign: diverse corpus x full operation matrix.

On-demand (not part of qa.sh — takes a few minutes):
  "$HOME/Library/Application Support/SamPDFStudio/engine-venv/bin/python3" Tests/qa_deep_matrix.py

Every operation output is re-opened and rendered to prove it is a valid,
displayable PDF (or valid export file). Prints a PASS/FAIL matrix.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[1] / "Engine" / "pdf_engine.py"
WORK = Path(tempfile.mkdtemp(prefix="qa-deep-"))
RESULTS: list[tuple[str, str, bool, str]] = []

import fitz  # noqa: E402


def run_engine(*args) -> dict:
    result = subprocess.run(
        [sys.executable, str(ENGINE), *[str(a) for a in args]],
        capture_output=True, text=True, timeout=180,
    )
    if result.returncode != 0:
        raise RuntimeError(f"exit {result.returncode}: {result.stdout[:300]} {result.stderr[:300]}")
    return json.loads(result.stdout)


def render_ok(path: Path) -> bool:
    doc = fitz.open(str(path))
    for index in range(min(3, doc.page_count)):
        pix = doc[index].get_pixmap(matrix=fitz.Matrix(0.5, 0.5))
        assert pix.width > 0
    doc.close()
    return True


def record(corpus: str, op: str, fn):
    try:
        fn()
        RESULTS.append((corpus, op, True, ""))
    except Exception as exc:  # noqa: BLE001
        RESULTS.append((corpus, op, False, f"{type(exc).__name__}: {exc}"))


# ---------------------------------------------------------------- corpus
def build_corpus() -> dict[str, Path]:
    corpus: dict[str, Path] = {}

    # 1. Base-14 font mix
    p = WORK / "base14.pdf"
    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 90), "Helvetica heading text", fontname="hebo", fontsize=18)
    page.insert_text((72, 130), "Times body paragraph with several words to edit inline.", fontname="tiro", fontsize=12)
    page.insert_text((72, 170), "Courier code line 1234567890", fontname="cour", fontsize=11)
    page.insert_text((72, 210), "Italic remark in Times", fontname="tiit", fontsize=12, color=(0.3, 0.3, 0.6))
    doc.save(str(p)); doc.close(); corpus["base14"] = p

    # 2. Embedded TTF fonts
    p = WORK / "embedded-ttf.pdf"
    doc = fitz.open()
    page = doc.new_page()
    georgia = "/System/Library/Fonts/Supplemental/Georgia.ttf"
    arial = "/System/Library/Fonts/Supplemental/Arial.ttf"
    trebuchet = "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf"
    page.insert_text((72, 90), "Georgia serif heading", fontname="Geo", fontfile=georgia, fontsize=17, color=(0.1, 0.1, 0.4))
    page.insert_text((72, 130), "Arial body text ready for editing tests here.", fontname="Ari", fontfile=arial, fontsize=12)
    page.insert_text((72, 170), "Trebuchet accent line", fontname="Tre", fontfile=trebuchet, fontsize=13, color=(0.5, 0.2, 0.1))
    doc.save(str(p)); doc.close(); corpus["embedded-ttf"] = p

    # 3. Real-world invoice with obfuscated subset fonts.
    # Point SAMPDF_REAL_INVOICE at a local PDF to include it in the matrix.
    real_invoice = os.environ.get("SAMPDF_REAL_INVOICE")
    if real_invoice:
        src = Path(real_invoice)
        if src.exists():
            p = WORK / "real-invoice.pdf"
            p.write_bytes(src.read_bytes())
            corpus["real-invoice"] = p

    # 4. Columnar / tabular layout (K-1 style)
    p = WORK / "columnar.pdf"
    doc = fitz.open()
    page = doc.new_page()
    for i, (label, amount) in enumerate([
        ("GUARANTEED PAYMENTS (OTHER THAN HEALTH INSURANCE)", "23,500."),
        ("ORDINARY BUSINESS INCOME", "18,998."),
        ("NET RENTAL REAL ESTATE", "1,250."),
    ]):
        y = 120 + i * 26
        page.insert_text((60, y), label + " " + "." * 30, fontname="cour", fontsize=9)
        page.insert_text((470, y), "$", fontname="cour", fontsize=9)
        page.insert_text((490, y), amount, fontname="cour", fontsize=9)
    doc.save(str(p)); doc.close(); corpus["columnar"] = p

    # 5. Mixed page sizes, multi-page
    p = WORK / "mixed-sizes.pdf"
    doc = fitz.open()
    for width, height, label in [(612, 792, "Letter page"), (595, 842, "A4 page"), (612, 1008, "Legal page")]:
        page = doc.new_page(width=width, height=height)
        page.insert_text((72, 90), f"{label} with text content", fontsize=13)
    doc.save(str(p)); doc.close(); corpus["mixed-sizes"] = p

    # 6. Scanned/image-only PDF (for OCR)
    p = WORK / "scanned.pdf"
    tmp = fitz.open()
    tp = tmp.new_page()
    tp.insert_text((72, 120), "SCANNED DOCUMENT SAMPLE", fontname="hebo", fontsize=20)
    tp.insert_text((72, 160), "This text exists only as pixels until OCR runs.", fontsize=13)
    pix = tp.get_pixmap(matrix=fitz.Matrix(2.5, 2.5))
    tmp.close()
    doc = fitz.open()
    page = doc.new_page()
    page.insert_image(page.rect, pixmap=pix)
    doc.save(str(p)); doc.close(); corpus["scanned"] = p

    # 7. Two-column layout
    p = WORK / "two-column.pdf"
    doc = fitz.open()
    page = doc.new_page()
    left = "Left column paragraph one with wrapped text inside a narrow box for testing block detection."
    right = "Right column paragraph that also wraps across multiple lines to test column separation."
    page.insert_textbox(fitz.Rect(50, 80, 290, 300), left, fontsize=11, fontname="helv")
    page.insert_textbox(fitz.Rect(320, 80, 560, 300), right, fontsize=11, fontname="tiro")
    doc.save(str(p)); doc.close(); corpus["two-column"] = p

    # 8. Unicode & special characters
    p = WORK / "unicode.pdf"
    doc = fitz.open()
    page = doc.new_page()
    page.insert_text((72, 100), "Café résumé naïve — em-dash & “quotes” fiancée", fontsize=13)
    page.insert_text((72, 140), "Symbols: © ® ™ € £ ¥ § ¶ • ± ÷", fontsize=12)
    doc.save(str(p)); doc.close(); corpus["unicode"] = p

    # 9. 30-page document
    p = WORK / "thirty-pages.pdf"
    doc = fitz.open()
    for i in range(30):
        page = doc.new_page()
        page.insert_text((72, 90), f"Page {i + 1} heading", fontname="hebo", fontsize=15)
        page.insert_text((72, 130), f"Body content for page {i + 1} to keep things realistic.", fontsize=11)
    doc.save(str(p)); doc.close(); corpus["thirty-pages"] = p

    return corpus


CORPUS = build_corpus()
print(f"corpus: {sorted(CORPUS)}\nwork dir: {WORK}\n")


# ------------------------------------------------- per-document operations
def first_block(path: Path) -> dict:
    blocks = run_engine("page-blocks", "--input", path, "--page", 1)["blocks"]
    assert blocks, "no blocks found"
    return max(blocks, key=lambda b: (b["rect"][2] - b["rect"][0]) * (b["rect"][3] - b["rect"][1]))


def rect_str(block: dict) -> str:
    r = block["rect"]
    return f"{r[0]},{r[1]},{r[2]},{r[3]}"


for name, src in CORPUS.items():
    out_dir = WORK / f"out-{name}"
    out_dir.mkdir(exist_ok=True)

    if name != "scanned":
        def edit_block(src=src, out=out_dir / "edited.pdf"):
            block = first_block(src)
            lines = block["text"].split("\n")
            lines[0] = lines[0][: max(4, len(lines[0]) // 2)] + " EDITED"
            payload = run_engine(
                "replace-block", "--input", src, "--output", out, "--page", 1,
                "--rect", rect_str(block), "--text", "\n".join(lines),
                "--line-height", block["line_height"],
            )
            assert payload["ok"]
            assert render_ok(out)
            with fitz.open(str(out)) as d:
                assert "EDITED" in d[0].get_text(), "edit not present"
        record(name, "edit-block", edit_block)

        def style_detect(src=src):
            block = first_block(src)
            assert block["fontsize"] > 4, "no size detected"
            assert block["fontname"], "no font detected"
        record(name, "style-detect", style_detect)

        def move_block(src=src, out=out_dir / "moved.pdf"):
            block = first_block(src)
            payload = run_engine(
                "move-block", "--input", src, "--output", out, "--page", 1,
                "--rect", rect_str(block), "--text", block["text"],
                "--dest-x", 150, "--dest-y", 500, "--line-height", block["line_height"],
            )
            assert payload["ok"]
            assert render_ok(out)
        record(name, "move-block", move_block)

        def redact(src=src, out=out_dir / "redacted.pdf"):
            block = first_block(src)
            word = next(w for w in block["text"].split() if len(w) >= 4)
            payload = run_engine("redact-text", "--input", src, "--output", out, "--find", word, "--label", "", "--page", 1)
            assert payload["ok"]
            assert render_ok(out)
        record(name, "redact", redact)

    def annotate(src=src, out=out_dir / "annotated.pdf"):
        payload = run_engine("add-note", "--input", src, "--output", out, "--page", 1, "--x", 300, "--y", 200, "--text", "QA note")
        assert payload["ok"] and render_ok(out)
    record(name, "note", annotate)

    def sign(src=src, out=out_dir / "signed.pdf"):
        payload = run_engine("add-signature", "--input", src, "--output", out, "--page", 1, "--x", 90, "--y", 600, "--width", 200, "--height", 44, "--text", "Sam Wasserman")
        assert payload["ok"] and render_ok(out)
        with fitz.open(str(out)) as d:
            assert "Sam Wasserman" in d[0].get_text()
    record(name, "signature", sign)

    def symbols(src=src, out=out_dir / "symbol.pdf"):
        payload = run_engine("add-symbol", "--input", src, "--output", out, "--page", 1, "--kind", "check", "--x", 400, "--y", 300)
        assert payload["ok"] and render_ok(out)
    record(name, "fill-sign-stamp", symbols)

    def redline(src=src, out=out_dir / "redline.pdf"):
        payload = run_engine("redline", "--input", src, "--output", out, "--page", 1, "--kind", "replace", "--rects", "72,85,300,105", "--note", "reviewer note")
        assert payload["ok"] and render_ok(out)
    record(name, "redline", redline)

    def page_numbers(src=src, out=out_dir / "numbered.pdf"):
        payload = run_engine("add-page-numbers", "--input", src, "--output", out, "--position", "bottom-center", "--number-format", "n-of-total", "--start", 1)
        assert payload["ok"] and render_ok(out)
    record(name, "page-numbers", page_numbers)

    def resize(src=src, out=out_dir / "resized.pdf"):
        payload = run_engine("resize-pages", "--input", src, "--output", out, "--width", 612, "--height", 792)
        assert payload["ok"] and render_ok(out)
        with fitz.open(str(out)) as d:
            assert {(round(p.rect.width), round(p.rect.height)) for p in d} == {(612, 792)}
    record(name, "resize", resize)

    def compress(src=src, out=out_dir / "compressed.pdf"):
        payload = run_engine("compress", "--input", src, "--output", out, "--quality", "medium")
        assert payload["ok"] and render_ok(out)
    record(name, "compress", compress)

    def password(src=src, out=out_dir / "locked.pdf"):
        payload = run_engine("set-password", "--input", src, "--output", out, "--password", "qa-pass")
        assert payload["ok"]
        with fitz.open(str(out)) as d:
            assert d.needs_pass and d.authenticate("qa-pass")
    record(name, "password", password)

    def export_docx(src=src, out=out_dir / "export.docx"):
        payload = run_engine("export-docx", "--input", src, "--output", out)
        assert payload["ok"] and out.exists() and out.stat().st_size > 2000
        import zipfile
        with zipfile.ZipFile(out) as z:
            assert "word/document.xml" in z.namelist()
    record(name, "export-word", export_docx)

    def export_text(src=src, out=out_dir / "export.txt"):
        payload = run_engine("export-text", "--input", src, "--output", out, "--format", "txt")
        assert payload["ok"] and out.exists()
    record(name, "export-text", export_text)

    def export_images(src=src, out=out_dir / "imgs"):
        out.mkdir(exist_ok=True)
        payload = run_engine("export-images", "--input", src, "--output-dir", out, "--format", "png", "--dpi", 100)
        assert payload["ok"] and any(out.glob("*.png"))
    record(name, "export-images", export_images)


# ---------------------------------------------------------- cross-file ops
def merge_all():
    out = WORK / "merged-all.pdf"
    args = ["merge", "--output", out]
    for path in CORPUS.values():
        args += ["--input", path]
    payload = run_engine(*args)
    assert payload["ok"] and render_ok(out)
    with fitz.open(str(out)) as d:
        expected = sum(fitz.open(str(p)).page_count for p in CORPUS.values())
        assert d.page_count == expected, f"{d.page_count} != {expected}"
    # then resize the mixed-size merge to uniform Letter
    out2 = WORK / "merged-uniform.pdf"
    assert run_engine("resize-pages", "--input", out, "--output", out2, "--width", 612, "--height", 792)["ok"]
    with fitz.open(str(out2)) as d:
        assert {(round(p.rect.width), round(p.rect.height)) for p in d} == {(612, 792)}
record("cross", "merge-all+uniform", merge_all)


def ocr_scanned():
    out = WORK / "ocred.pdf"
    payload = run_engine("ocr", "--input", CORPUS["scanned"], "--output", out, "--language", "eng")
    assert payload["ok"]
    with fitz.open(str(out)) as d:
        text = d[0].get_text().upper()
        assert "SCANNED" in text and "DOCUMENT" in text, f"OCR text missing: {text[:120]!r}"
record("cross", "ocr", ocr_scanned)


def chained_sequence():
    """Many operations in a row on one document — the no-crash stress path."""
    current = CORPUS["base14"]
    steps = [
        ("replace-block", lambda src, out: run_engine(
            "replace-block", "--input", src, "--output", out, "--page", 1,
            "--rect", rect_str(first_block(src)), "--text", "Edited heading text", "--line-height", 0)),
        ("add-note", lambda src, out: run_engine("add-note", "--input", src, "--output", out, "--page", 1, "--x", 300, "--y", 300, "--text", "chain")),
        ("add-signature", lambda src, out: run_engine("add-signature", "--input", src, "--output", out, "--page", 1, "--x", 80, "--y", 650, "--width", 180, "--height", 40, "--text", "Chain Sig")),
        ("add-symbol", lambda src, out: run_engine("add-symbol", "--input", src, "--output", out, "--page", 1, "--kind", "cross", "--x", 450, "--y", 400)),
        ("redline", lambda src, out: run_engine("redline", "--input", src, "--output", out, "--page", 1, "--kind", "squiggly", "--rects", "72,120,300,140")),
        ("page-numbers", lambda src, out: run_engine("add-page-numbers", "--input", src, "--output", out, "--position", "bottom-right", "--number-format", "n", "--start", 1)),
        ("resize", lambda src, out: run_engine("resize-pages", "--input", src, "--output", out, "--width", 595, "--height", 842)),
        ("compress", lambda src, out: run_engine("compress", "--input", src, "--output", out, "--quality", "high")),
        ("password", lambda src, out: run_engine("set-password", "--input", src, "--output", out, "--password", "chain")),
    ]
    for index, (label, fn) in enumerate(steps):
        out = WORK / f"chain-{index}-{label}.pdf"
        payload = fn(current, out)
        assert payload["ok"], f"step {label} failed"
        current = out
    with fitz.open(str(current)) as d:
        assert d.needs_pass and d.authenticate("chain")
        assert d.page_count == 1
record("cross", "chained-9-ops", chained_sequence)


# -------------------------------------------------------------- report
print(f"{'corpus':14} {'operation':20} result")
print("-" * 60)
failures = 0
for corpus, op, ok, err in RESULTS:
    mark = "PASS" if ok else "FAIL"
    if not ok:
        failures += 1
    print(f"{corpus:14} {op:20} {mark}  {err[:70]}")
print("-" * 60)
print(f"total={len(RESULTS)} failures={failures}")
sys.exit(1 if failures else 0)
