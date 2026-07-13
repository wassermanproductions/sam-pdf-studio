#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The venv must live OUTSIDE iCloud-synced folders (Documents/Desktop).
# iCloud evicts rarely-touched files ("dataless"), which makes Python imports
# hang while macOS re-downloads them. Application Support is never synced.
VENV_DIR="${SAMPDF_VENV_DIR:-$HOME/Library/Application Support/SamPDFStudio/engine-venv}"

# Prefer a modern python3 if one is on PATH, else fall back to common locations.
DEFAULT_PYTHON="$(command -v python3.13 || command -v python3.12 || command -v python3 || true)"
if [[ -z "$DEFAULT_PYTHON" || ! -x "$DEFAULT_PYTHON" ]]; then
  DEFAULT_PYTHON="/usr/local/bin/python3.13"
fi
if [[ ! -x "$DEFAULT_PYTHON" ]]; then
  DEFAULT_PYTHON="/usr/bin/python3"
fi
PYTHON_BOOTSTRAP="${PYTHON_BOOTSTRAP:-$DEFAULT_PYTHON}"

if [[ "${FORCE_BOOTSTRAP:-0}" == "1" ]]; then
  rm -rf "$VENV_DIR"
fi

if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
  mkdir -p "$(dirname "$VENV_DIR")"
  "$PYTHON_BOOTSTRAP" -m venv "$VENV_DIR"
fi

if [[ "${FORCE_BOOTSTRAP:-0}" != "1" ]] && "$VENV_DIR/bin/python3" "$ROOT_DIR/Engine/pdf_engine.py" health >/dev/null 2>&1; then
  "$VENV_DIR/bin/python3" "$ROOT_DIR/Engine/pdf_engine.py" health
  exit 0
fi

"$VENV_DIR/bin/python3" -m pip install --upgrade pip setuptools wheel
"$VENV_DIR/bin/python3" -m pip install -r "$ROOT_DIR/Engine/requirements.txt"

missing=()
for bin in qpdf tesseract gs; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    missing+=("$bin")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Missing system OCR tools: ${missing[*]}" >&2
  echo "Install with: brew install qpdf tesseract ghostscript" >&2
  exit 1
fi

"$VENV_DIR/bin/python3" "$ROOT_DIR/Engine/pdf_engine.py" health
