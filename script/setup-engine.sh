#!/usr/bin/env bash
# Distribution first-run bootstrap for Sam PDF Studio's Python engine.
#
# Runs on a fresh Mac that never saw the dev build — either from inside the
# packaged app (Contents/Resources/setup-engine.sh) or from the repo's script/
# folder. It creates the engine venv, installs the Python dependencies in two
# tiers (core must succeed, optional are best-effort), and treats the system
# OCR tools (qpdf/tesseract/gs) as optional. It exits 0 as long as the venv can
# import the core PDF stack (fitz + pypdf), regardless of OCR availability.
#
# It deliberately does NOT use `set -e`: optional-package failures are expected
# on some machines and must never abort the run.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[setup-engine] %s\n' "$*"; }
warn() { printf '[setup-engine] WARNING: %s\n' "$*" >&2; }

# The venv must live OUTSIDE iCloud-synced folders (Documents/Desktop). iCloud
# evicts rarely-touched files ("dataless"), which makes Python imports hang
# while macOS re-downloads them. Application Support is never synced.
VENV_DIR="${SAMPDF_VENV_DIR:-$HOME/Library/Application Support/SamPDFStudio/engine-venv}"

# Locate the engine script + requirements. Prefer the explicit env overrides
# (the app points these at its bundled Resources), then files sitting next to
# this script (the .app layout), then the repo layout one directory up.
ENGINE_SCRIPT="${SAMPDF_ENGINE_SCRIPT:-}"
if [[ -z "$ENGINE_SCRIPT" ]]; then
  if [[ -f "$SELF_DIR/pdf_engine.py" ]]; then
    ENGINE_SCRIPT="$SELF_DIR/pdf_engine.py"
  else
    ENGINE_SCRIPT="$SELF_DIR/../Engine/pdf_engine.py"
  fi
fi

REQUIREMENTS="${SAMPDF_REQUIREMENTS:-}"
if [[ -z "$REQUIREMENTS" ]]; then
  if [[ -f "$SELF_DIR/requirements.txt" ]]; then
    REQUIREMENTS="$SELF_DIR/requirements.txt"
  else
    REQUIREMENTS="$SELF_DIR/../Engine/requirements.txt"
  fi
fi

# Prefer a modern python3 to build the venv from, else fall back to /usr/bin.
DEFAULT_PYTHON="$(command -v python3.13 || command -v python3.12 || command -v python3 || true)"
if [[ -z "$DEFAULT_PYTHON" || ! -x "$DEFAULT_PYTHON" ]]; then
  DEFAULT_PYTHON="/usr/bin/python3"
fi
PYTHON_BOOTSTRAP="${PYTHON_BOOTSTRAP:-$DEFAULT_PYTHON}"

log "Engine script: $ENGINE_SCRIPT"
log "Requirements:  $REQUIREMENTS"
log "Venv:          $VENV_DIR"
log "Bootstrap py:  $PYTHON_BOOTSTRAP"

if [[ "${FORCE_BOOTSTRAP:-0}" == "1" ]]; then
  rm -rf "$VENV_DIR"
fi

VENV_PY="$VENV_DIR/bin/python3"

if [[ ! -x "$VENV_PY" ]]; then
  log "Creating virtual environment…"
  mkdir -p "$(dirname "$VENV_DIR")"
  if ! "$PYTHON_BOOTSTRAP" -m venv "$VENV_DIR"; then
    warn "Could not create the virtual environment with $PYTHON_BOOTSTRAP."
    exit 1
  fi
fi

if [[ ! -x "$VENV_PY" ]]; then
  warn "Virtual environment python is missing at $VENV_PY."
  exit 1
fi

log "Upgrading pip / setuptools / wheel…"
"$VENV_PY" -m pip install --upgrade pip setuptools wheel \
  || warn "Could not upgrade pip/setuptools/wheel (continuing anyway)."

# Return the pinned requirement line (e.g. "pymupdf>=1.24") for a package from
# the requirements file so version constraints are honored, or just the bare
# name if it is not listed there.
req_spec() {
  local name="$1" line=""
  if [[ -f "$REQUIREMENTS" ]]; then
    line="$(grep -iE "^${name}([[:space:]<>=!~]|\$)" "$REQUIREMENTS" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  fi
  printf '%s' "${line:-$name}"
}

# Tier 1 — core packages. The app's basic tools (view/edit/merge/export) cannot
# function without these, so a failure here is a real problem.
CORE_NAMES=(pymupdf pypdf pillow reportlab openpyxl python-pptx)
CORE_SPECS=()
for name in "${CORE_NAMES[@]}"; do
  CORE_SPECS+=("$(req_spec "$name")")
done

log "Installing core packages: ${CORE_SPECS[*]}"
if ! "$VENV_PY" -m pip install "${CORE_SPECS[@]}"; then
  warn "Bulk core install failed; retrying each package individually…"
  for spec in "${CORE_SPECS[@]}"; do
    "$VENV_PY" -m pip install "$spec" \
      || warn "Core package failed to install: $spec"
  done
fi

# Tier 2 — optional packages. These power extra conversions/OCR; a failure is
# logged but never fails the run (older Pythons or offline wheels may lack them).
OPTIONAL_NAMES=(pdfplumber pdf2docx ocrmypdf pymupdf4llm)
for name in "${OPTIONAL_NAMES[@]}"; do
  spec="$(req_spec "$name")"
  log "Installing optional package: $spec"
  "$VENV_PY" -m pip install "$spec" \
    || warn "Optional package skipped (not required): $spec"
done

# System OCR tools are OPTIONAL. Warn if absent, but never fail the run — OCR
# features light up later once the user installs them.
missing_bins=()
for bin in qpdf tesseract gs; do
  command -v "$bin" >/dev/null 2>&1 || missing_bins+=("$bin")
done
if (( ${#missing_bins[@]} > 0 )); then
  warn "System OCR tools not found: ${missing_bins[*]}"
  warn "OCR/compression features stay disabled until you run: brew install qpdf tesseract ghostscript"
fi

# Report full engine health for the logs. This exits non-zero when the optional
# packages or OCR tools are absent, which is fine here — the real gate below is
# whether the core PDF stack imports.
log "Engine health report:"
"$VENV_PY" "$ENGINE_SCRIPT" health || true

# Core gate: the venv MUST be able to import the core PDF stack. Everything
# else (OCR, optional conversions) is allowed to be missing.
if "$VENV_PY" -c "import fitz, pypdf" >/dev/null 2>&1; then
  log "Core engine ready (fitz + pypdf import OK)."
  exit 0
fi

warn "Core engine is NOT ready — the venv could not import fitz + pypdf."
exit 1
