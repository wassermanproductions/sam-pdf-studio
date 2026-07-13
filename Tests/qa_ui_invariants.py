#!/usr/bin/env python3
"""Source-level regression checks for the behavioral rules Sam cares about.

These guard the interaction contract:
- Reader mode never routes clicks into edit operations.
- Edit mode always starts on the Text tool, never Redact.
- Redaction only happens with the Redact tool explicitly active, and asks first.
- The inline text editor stays tight and transparent.
- Every document mutation flows through the version stack (undo/redo).
- A plain PDF copy export is always available.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Sources" / "SamPDFStudio"


def read(relative: str) -> str:
    return (SRC / relative).read_text(encoding="utf-8")


def assert_contains(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"Missing invariant: {label}")


def assert_absent(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"Forbidden pattern present: {label}")


def main() -> int:
    app_store = read("Stores/AppStore.swift")
    content_view = read("Views/ContentView.swift")
    workspace_view = read("Views/PDFWorkspaceView.swift")
    preview_view = read("Views/PDFPreviewView.swift")
    operations = read("Models/PDFOperation.swift")
    session = read("Models/DocumentSession.swift")

    # Reader mode stays a pure reader; canvas edit paths are explicitly gated.
    assert_contains(workspace_view, "isEditing: store.selectedOperation == .edit", "preview edit mode is explicit")
    assert_contains(workspace_view, "isAnnotating: store.selectedOperation == .annotate", "preview annotate mode is explicit")
    assert_contains(preview_view, "let isEditing: Bool", "preview receives edit mode")
    assert_contains(preview_view, "var isEditingEnabled = false", "PDFView tracks edit mode")
    assert_contains(preview_view, "var isAnnotatingEnabled = false", "PDFView tracks annotate mode")
    assert_contains(preview_view, "if isEditingEnabled {", "edit mouse paths are gated")
    assert_contains(preview_view, "if isAnnotatingEnabled", "annotate mouse paths are gated")
    assert_contains(preview_view, "super.mouseDown(with: event)", "ungated clicks fall through to normal reading")
    assert_contains(preview_view, "view.isEditingEnabled = isEditing", "SwiftUI state reaches AppKit PDF view")

    # Inline text editor (new text boxes) stays tight and transparent.
    assert_contains(preview_view, "drawsBackground = false", "inline text editor has no white fill")
    assert_contains(preview_view, "backgroundColor = .clear", "inline text editor is transparent")
    assert_contains(preview_view, "layer?.borderWidth = 0", "inline text editor has no heavy border")

    # Block editing works like PDF Expert: click a paragraph, edit in place,
    # drag the frame to move, Esc cancels.
    assert_contains(preview_view, "class BlockEditorView", "block editor exists")
    assert_contains(preview_view, "characterIndexForInsertion", "click places the caret inside the block")
    assert_contains(preview_view, "onMoved", "block frame is draggable")
    assert_contains(app_store, "func editBlock", "store opens blocks for editing")
    assert_contains(app_store, "func commitBlockEdit", "store commits block edits")
    assert_contains(app_store, "func moveActiveBlock", "store moves blocks")
    engine_src = (ROOT / "Engine" / "pdf_engine.py").read_text(encoding="utf-8")
    assert_contains(engine_src, "def cmd_block_at", "engine finds blocks at a click")
    assert_contains(engine_src, "def cmd_replace_block", "engine re-renders whole blocks")

    # Tool gating in the store.
    assert_contains(app_store, "guard selectedOperation == .edit, selectedEditTool == .contentText", "text replacement requires text tool")
    assert_contains(app_store, "guard selectedOperation == .edit, selectedEditTool == .grab", "region actions require grab tool")
    assert_contains(app_store, "guard selectedOperation == .edit, selectedEditTool == .redact", "redaction requires redact tool")
    assert_contains(app_store, "guard selectedOperation == .annotate", "markup requires annotate mode")

    # Edit mode must open on the Text tool and never silently switch to Redact.
    assert_contains(app_store, "selectedEditTool = .contentText", "edit mode defaults to the text tool")
    assert_absent(app_store, "selectedEditTool = .redact", "AppStore must not silently switch into redaction mode")
    assert_absent(app_store, "func useSelectedTextForRedact", "hidden selected-text-to-redact helper must stay removed")

    # Redaction is confirmed with the user and never labelled.
    redact_body = app_store.split("func redactSelectedText")[1].split("func ")[0]
    if "confirm(" not in redact_body:
        raise AssertionError("Redaction must ask for confirmation before running")
    if 'label: ""' not in redact_body:
        raise AssertionError("Redaction must not stamp a visible label")

    # The redact button in the tool strip only renders for the redact tool.
    redact_calls = [m.start() for m in re.finditer(r"store\.redactSelectedText\(\)", content_view)]
    for position in redact_calls:
        prefix = content_view[:position]
        case_index = prefix.rfind("case .")
        if case_index == -1 or not prefix[case_index:].startswith("case .redact"):
            raise AssertionError("Redact button must be gated under the redact tool case")

    # Every mutation goes through the version stack.
    assert_contains(app_store, "session.commit(output)", "engine ops commit versions")
    assert_contains(app_store, "session.commit(url)", "PDFKit ops commit versions")
    assert_contains(session, "func undo()", "session supports undo")
    assert_contains(session, "func redo()", "session supports redo")
    assert_contains(app_store, "func undo()", "store exposes undo")
    assert_contains(app_store, "func redo()", "store exposes redo")

    # Saving is explicit; the original is never touched by ordinary operations.
    assert_contains(session, "func saveToOriginal()", "save writes back to the original explicitly")
    ordinary_ops = app_store.split("func save()")[0]
    assert_absent(ordinary_ops, "saveToOriginal", "no operation may auto-save over the original")

    # A plain PDF copy export stays available.
    assert_contains(app_store, "func exportPDFCopy()", "PDF export copies the current edited PDF")
    assert_contains(content_view, "store.exportPDFCopy()", "PDF export action is visible")

    # Mode list stays lean — no Jobs/engine plumbing exposed as a mode.
    assert_absent(operations, "case jobs", "jobs must not be a top-level mode")

    print("UI invariants ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
