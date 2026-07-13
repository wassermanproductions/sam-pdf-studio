#!/usr/bin/env node
/**
 * Sam PDF Studio MCP server — zero-dependency Node >=18 stdio bridge.
 *
 * Speaks the MCP stdio transport: newline-delimited JSON-RPC 2.0 on
 * stdin/stdout (NOT Content-Length framed). Each tools/call is forwarded to
 * the Sam PDF Studio PyMuPDF engine (pdf_engine.py), run headlessly as a
 * subprocess — no GUI required. Every operation reads an input path and
 * writes a new output path; inputs are never modified in place.
 *
 * Uses only node built-ins + child_process — run directly with `node`.
 */

import { join, dirname } from 'node:path'
import { homedir } from 'node:os'
import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const PROTOCOL_VERSION = '2024-11-05'
const HOME = homedir()
// Directory of this server file, so an mcp/ folder shipped inside the
// sam-pdf-studio app repo can find the engine at ../Engine relative to itself.
const HERE = dirname(fileURLToPath(import.meta.url))

/* ------------------------------- engine --------------------------------- */

const DEFAULT_PYTHON = join(
  HOME,
  'Library',
  'Application Support',
  'SamPDFStudio',
  'engine-venv',
  'bin',
  'python3'
)

const SCRIPT_CANDIDATES = [
  // Installed app bundles.
  '/Applications/SamPDFStudio.app/Contents/Resources/pdf_engine.py',
  join(HOME, 'Applications', 'SamPDFStudio.app', 'Contents', 'Resources', 'pdf_engine.py'),
  // Shipped inside the app repo as `mcp/…` → engine at `../Engine/…`.
  join(HERE, '..', 'Engine', 'pdf_engine.py'),
  // A sam-pdf-studio source checkout sitting next to this repo.
  join(HERE, '..', 'sam-pdf-studio', 'Engine', 'pdf_engine.py'),
  join(HERE, '..', 'SamPDFStudio', 'Engine', 'pdf_engine.py')
]

const INSTALL_HINT =
  'Install or build Sam PDF Studio (https://github.com/wassermanproductions/sam-pdf-studio) so the engine venv exists, or set SAMPDF_ENGINE_PYTHON and SAMPDF_ENGINE_SCRIPT.'

function resolvePython() {
  return process.env.SAMPDF_ENGINE_PYTHON || DEFAULT_PYTHON
}

function resolveScript() {
  if (process.env.SAMPDF_ENGINE_SCRIPT) return process.env.SAMPDF_ENGINE_SCRIPT
  for (const candidate of SCRIPT_CANDIDATES) if (existsSync(candidate)) return candidate
  return null
}

// Spawn the engine: `python pdf_engine.py <subcommand> ...argv`, capture stdout,
// parse the JSON the engine prints, and return it. The engine always prints a
// JSON object with an `ok` field (even on failure) and exits 0/1 accordingly,
// so we parse stdout regardless of exit code and only fall back to stderr when
// stdout is not parseable.
function runEngine(subcommand, argv) {
  return new Promise((resolve) => {
    const python = resolvePython()
    const script = resolveScript()
    if (!existsSync(python)) {
      resolve({ ok: false, error: `Engine Python not found at ${python}. ${INSTALL_HINT}` })
      return
    }
    if (!script) {
      resolve({ ok: false, error: `Engine script pdf_engine.py not found. ${INSTALL_HINT}` })
      return
    }
    // OCR and image tooling (tesseract, ghostscript, qpdf) live in Homebrew.
    const env = {
      ...process.env,
      PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ''}`
    }
    let child
    try {
      child = spawn(python, [script, subcommand, ...argv], { env })
    } catch (err) {
      resolve({ ok: false, error: `Failed to spawn engine: ${err && err.message ? err.message : err}. ${INSTALL_HINT}` })
      return
    }
    let out = ''
    let errText = ''
    child.stdout.on('data', (chunk) => {
      out += chunk
    })
    child.stderr.on('data', (chunk) => {
      errText += chunk
    })
    child.on('error', (err) => {
      resolve({ ok: false, error: `Failed to spawn engine: ${err.message}. ${INSTALL_HINT}` })
    })
    child.on('close', (code) => {
      const trimmed = out.trim()
      if (trimmed) {
        try {
          resolve(JSON.parse(trimmed))
          return
        } catch {
          /* fall through to error reporting */
        }
      }
      resolve({
        ok: false,
        error: errText.trim() || `Engine exited with code ${code} and produced no parseable output.`
      })
    })
  })
}

/* --------------------------------- tools -------------------------------- */

const IN = 'Absolute path to the source PDF (read-only, never modified).'
const OUT = 'Absolute path to write the resulting PDF. A new file is written; the input is left untouched.'
const PAGES = 'Page selection, 1-based, e.g. "1,3,5-8". Omit to apply to all pages.'

// Each tool maps to an engine subcommand. `args` describes how to convert the
// tool's JSON arguments into `--flag value` argv:
//   type 'value'  -> --flag <value>            (skipped when omitted)
//   type 'array'  -> --flag <v> repeated       (from a string[])
//   type 'bool'   -> --flag                     (only when true; store_true)
//   type 'boolNo' -> --flag / --no-flag         (BooleanOptionalAction)
const TOOLS = [
  {
    name: 'health',
    subcommand: 'health',
    description:
      'Call FIRST to verify the engine is installed and working. Reports the engine version, the Python interpreter, and the status of every required package (PyMuPDF, pypdf, pdf2docx, ocrmypdf, etc.) and binary (qpdf, tesseract, ghostscript). No files are touched.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    args: []
  },
  {
    name: 'metadata',
    subcommand: 'metadata',
    description: 'Return a PDF’s page count and document metadata (title, author, producer, dates, etc.). Read-only.',
    inputSchema: {
      type: 'object',
      properties: { input: { type: 'string', description: IN } },
      required: ['input'],
      additionalProperties: false
    },
    args: [{ name: 'input', flag: '--input', type: 'value' }]
  },
  {
    name: 'merge_pdfs',
    subcommand: 'merge',
    description: 'Merge two or more PDFs, in the given order, into a single new PDF written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: {
          type: 'array',
          items: { type: 'string' },
          description: 'Ordered list of absolute PDF paths to concatenate (two or more).'
        },
        output: { type: 'string', description: OUT }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'array' },
      { name: 'output', flag: '--output', type: 'value' }
    ]
  },
  {
    name: 'split_pdf',
    subcommand: 'split',
    description:
      'Split a PDF into separate one-page (or selected-page) PDF files written into output_dir. Optionally restrict to a page selection.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output_dir: { type: 'string', description: 'Absolute path to a directory to write the split page files into.' },
        pages: { type: 'string', description: PAGES }
      },
      required: ['input', 'output_dir'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output_dir', flag: '--output-dir', type: 'value' },
      { name: 'pages', flag: '--pages', type: 'value' }
    ]
  },
  {
    name: 'extract_pages',
    subcommand: 'extract-pages',
    description: 'Extract a subset of pages into a new PDF written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        pages: { type: 'string', description: 'Pages to keep, 1-based, e.g. "1,3,5-8".' }
      },
      required: ['input', 'output', 'pages'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'pages', flag: '--pages', type: 'value' }
    ]
  },
  {
    name: 'delete_pages',
    subcommand: 'delete-pages',
    description: 'Delete the given pages and write the remaining pages to a new PDF at output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        pages: { type: 'string', description: 'Pages to remove, 1-based, e.g. "2,4,6-9".' }
      },
      required: ['input', 'output', 'pages'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'pages', flag: '--pages', type: 'value' }
    ]
  },
  {
    name: 'rotate_pages',
    subcommand: 'rotate-pages',
    description: 'Rotate pages by a multiple of 90 degrees and write the result to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        pages: { type: 'string', description: PAGES },
        degrees: {
          type: 'integer',
          enum: [90, 180, 270, -90, -180, -270],
          description: 'Rotation in degrees (clockwise positive). Default 90.'
        }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'pages', flag: '--pages', type: 'value' },
      { name: 'degrees', flag: '--degrees', type: 'value' }
    ]
  },
  {
    name: 'replace_text',
    subcommand: 'replace-text',
    description:
      'Find literal text and replace it throughout the document (or on one page / within one rect), writing a new PDF to output. By default it matches the original run’s style.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        find: { type: 'string', description: 'Exact text to find.' },
        replace: { type: 'string', description: 'Replacement text.' },
        font_size: { type: 'number', description: 'Font size for replacement text when not auto-sizing. Default 11.' },
        expand: { type: 'number', description: 'Percent to expand the replacement box to fit text. Default 160.' },
        auto_size: { type: 'boolean', description: 'Automatically size replacement text to fit the original box.' },
        match_style: { type: 'boolean', description: 'Match the original text’s font/color/size. Default true.' },
        page: { type: 'integer', description: 'Restrict to a single 1-based page.' },
        rect: { type: 'string', description: 'Restrict to a rectangle "x0,y0,x1,y1" in PDF points.' }
      },
      required: ['input', 'output', 'find', 'replace'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'find', flag: '--find', type: 'value' },
      { name: 'replace', flag: '--replace', type: 'value' },
      { name: 'font_size', flag: '--font-size', type: 'value' },
      { name: 'expand', flag: '--expand', type: 'value' },
      { name: 'auto_size', flag: '--auto-size', type: 'bool' },
      { name: 'match_style', flag: '--match-style', noFlag: '--no-match-style', type: 'boolNo' },
      { name: 'page', flag: '--page', type: 'value' },
      { name: 'rect', flag: '--rect', type: 'value' }
    ]
  },
  {
    name: 'redact_text',
    subcommand: 'redact-text',
    description:
      'Permanently redact (black out and remove underlying text of) every occurrence of the given text, writing a new PDF to output. Optionally scope to pages / a page / a rect and stamp a label over the box.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        find: { type: 'string', description: 'Exact text to redact.' },
        label: { type: 'string', description: 'Optional label stamped over each redaction box.' },
        pages: { type: 'string', description: PAGES },
        page: { type: 'integer', description: 'Restrict to a single 1-based page.' },
        rect: { type: 'string', description: 'Restrict to a rectangle "x0,y0,x1,y1" in PDF points.' }
      },
      required: ['input', 'output', 'find'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'find', flag: '--find', type: 'value' },
      { name: 'label', flag: '--label', type: 'value' },
      { name: 'pages', flag: '--pages', type: 'value' },
      { name: 'page', flag: '--page', type: 'value' },
      { name: 'rect', flag: '--rect', type: 'value' }
    ]
  },
  {
    name: 'add_text',
    subcommand: 'add-text',
    description:
      'Draw a line of text at x,y on a page (PDF points, origin top-left) and write a new PDF to output. Supports font, size, color, bold/italic/underline and alignment.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        page: { type: 'integer', description: '1-based page number to draw on.' },
        x: { type: 'number', description: 'X position in PDF points.' },
        y: { type: 'number', description: 'Y position in PDF points.' },
        text: { type: 'string', description: 'The text to draw.' },
        font_size: { type: 'number', description: 'Font size in points. Default 12.' },
        font: { type: 'string', description: 'Font name. Default "Helvetica".' },
        color: { type: 'string', description: 'Hex color, e.g. "#000000". Default black.' },
        bold: { type: 'boolean', description: 'Bold text.' },
        italic: { type: 'boolean', description: 'Italic text.' },
        underline: { type: 'boolean', description: 'Underline text.' },
        align: { type: 'string', enum: ['left', 'center', 'right'], description: 'Text alignment. Default left.' }
      },
      required: ['input', 'output', 'page', 'x', 'y', 'text'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'page', flag: '--page', type: 'value' },
      { name: 'x', flag: '--x', type: 'value' },
      { name: 'y', flag: '--y', type: 'value' },
      { name: 'text', flag: '--text', type: 'value' },
      { name: 'font_size', flag: '--font-size', type: 'value' },
      { name: 'font', flag: '--font', type: 'value' },
      { name: 'color', flag: '--color', type: 'value' },
      { name: 'bold', flag: '--bold', type: 'bool' },
      { name: 'italic', flag: '--italic', type: 'bool' },
      { name: 'underline', flag: '--underline', type: 'bool' },
      { name: 'align', flag: '--align', type: 'value' }
    ]
  },
  {
    name: 'add_image',
    subcommand: 'add-image',
    description: 'Place an image (PNG/JPG) at x,y with the given width and height on a page, writing a new PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        image: { type: 'string', description: 'Absolute path to the image file to place.' },
        page: { type: 'integer', description: '1-based page number.' },
        x: { type: 'number', description: 'X position in PDF points.' },
        y: { type: 'number', description: 'Y position in PDF points.' },
        width: { type: 'number', description: 'Placement width in points.' },
        height: { type: 'number', description: 'Placement height in points.' }
      },
      required: ['input', 'output', 'image', 'page', 'x', 'y', 'width', 'height'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'image', flag: '--image', type: 'value' },
      { name: 'page', flag: '--page', type: 'value' },
      { name: 'x', flag: '--x', type: 'value' },
      { name: 'y', flag: '--y', type: 'value' },
      { name: 'width', flag: '--width', type: 'value' },
      { name: 'height', flag: '--height', type: 'value' }
    ]
  },
  {
    name: 'add_link',
    subcommand: 'add-link',
    description: 'Add a clickable URL hyperlink over a rectangle (x,y,width,height) on a page, writing a new PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        page: { type: 'integer', description: '1-based page number.' },
        x: { type: 'number', description: 'X of the link box in PDF points.' },
        y: { type: 'number', description: 'Y of the link box in PDF points.' },
        width: { type: 'number', description: 'Width of the link box in points.' },
        height: { type: 'number', description: 'Height of the link box in points.' },
        url: { type: 'string', description: 'Destination URL.' }
      },
      required: ['input', 'output', 'page', 'x', 'y', 'width', 'height', 'url'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'page', flag: '--page', type: 'value' },
      { name: 'x', flag: '--x', type: 'value' },
      { name: 'y', flag: '--y', type: 'value' },
      { name: 'width', flag: '--width', type: 'value' },
      { name: 'height', flag: '--height', type: 'value' },
      { name: 'url', flag: '--url', type: 'value' }
    ]
  },
  {
    name: 'compress_pdf',
    subcommand: 'compress',
    description: 'Reduce PDF file size by recompressing images and streams, writing a new PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        quality: {
          type: 'string',
          enum: ['low', 'medium', 'high'],
          description: 'Compression aggressiveness; "low" = smallest file, "high" = best quality. Default medium.'
        }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'quality', flag: '--quality', type: 'value' }
    ]
  },
  {
    name: 'add_page_numbers',
    subcommand: 'add-page-numbers',
    description: 'Stamp page numbers onto every page and write a new PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        position: {
          type: 'string',
          description: 'Placement, e.g. "bottom-center", "bottom-right", "top-left". Default "bottom-center".'
        },
        number_format: {
          type: 'string',
          description: 'Format token: "n" for just the number, or a template like "Page n of N". Default "n".'
        },
        start: { type: 'integer', description: 'Number to assign to the first page. Default 1.' },
        font_size: { type: 'number', description: 'Font size in points. Default 11.' },
        margin: { type: 'number', description: 'Margin from the page edge in points. Default 28.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'position', flag: '--position', type: 'value' },
      { name: 'number_format', flag: '--number-format', type: 'value' },
      { name: 'start', flag: '--start', type: 'value' },
      { name: 'font_size', flag: '--font-size', type: 'value' },
      { name: 'margin', flag: '--margin', type: 'value' }
    ]
  },
  {
    name: 'resize_pages',
    subcommand: 'resize-pages',
    description: 'Scale every page to a new width and height (in PDF points) and write a new PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        width: { type: 'number', description: 'Target page width in points (e.g. 612 for US Letter).' },
        height: { type: 'number', description: 'Target page height in points (e.g. 792 for US Letter).' }
      },
      required: ['input', 'output', 'width', 'height'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'width', flag: '--width', type: 'value' },
      { name: 'height', flag: '--height', type: 'value' }
    ]
  },
  {
    name: 'set_password',
    subcommand: 'set-password',
    description: 'Encrypt the PDF with a user/open password and write a new protected PDF to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        password: { type: 'string', description: 'Password required to open the resulting PDF.' }
      },
      required: ['input', 'output', 'password'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'password', flag: '--password', type: 'value' }
    ]
  },
  {
    name: 'ocr',
    subcommand: 'ocr',
    description:
      'Run OCR on a scanned PDF to add a searchable text layer, writing a new PDF to output. Requires tesseract (installed with Sam PDF Studio).',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: OUT },
        language: { type: 'string', description: 'Tesseract language code, e.g. "eng", "fra", "deu". Default "eng".' },
        force: { type: 'boolean', description: 'Re-OCR pages that already contain text.' },
        page: { type: 'integer', description: 'Restrict OCR to a single 1-based page.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'language', flag: '--language', type: 'value' },
      { name: 'force', flag: '--force', type: 'bool' },
      { name: 'page', flag: '--page', type: 'value' }
    ]
  },
  {
    name: 'export_docx',
    subcommand: 'export-docx',
    description: 'Convert the PDF to an editable Word .docx file written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: 'Absolute path to write the .docx file.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' }
    ]
  },
  {
    name: 'export_xlsx',
    subcommand: 'export-xlsx',
    description: 'Extract tables from the PDF into an Excel .xlsx workbook written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: 'Absolute path to write the .xlsx file.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' }
    ]
  },
  {
    name: 'export_pptx',
    subcommand: 'export-pptx',
    description: 'Convert each PDF page to a slide in a PowerPoint .pptx file written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: 'Absolute path to write the .pptx file.' },
        dpi: { type: 'integer', description: 'Rendering resolution for each slide. Default 160.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'dpi', flag: '--dpi', type: 'value' }
    ]
  },
  {
    name: 'export_text',
    subcommand: 'export-text',
    description: 'Extract the PDF’s text to a .txt, Markdown, or HTML file written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output: { type: 'string', description: 'Absolute path to write the text file.' },
        format: { type: 'string', enum: ['txt', 'md', 'html'], description: 'Output format. Default txt.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'format', flag: '--format', type: 'value' }
    ]
  },
  {
    name: 'export_images',
    subcommand: 'export-images',
    description: 'Render each PDF page to an image file (PNG or JPG) written into output_dir.',
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'string', description: IN },
        output_dir: { type: 'string', description: 'Absolute path to a directory to write the page images into.' },
        format: { type: 'string', enum: ['png', 'jpg'], description: 'Image format. Default png.' },
        dpi: { type: 'integer', description: 'Rendering resolution in DPI. Default 200.' }
      },
      required: ['input', 'output_dir'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'value' },
      { name: 'output_dir', flag: '--output-dir', type: 'value' },
      { name: 'format', flag: '--format', type: 'value' },
      { name: 'dpi', flag: '--dpi', type: 'value' }
    ]
  },
  {
    name: 'images_to_pdf',
    subcommand: 'images-to-pdf',
    description: 'Combine one or more images (PNG/JPG), in order, into a single new PDF written to output.',
    inputSchema: {
      type: 'object',
      properties: {
        input: {
          type: 'array',
          items: { type: 'string' },
          description: 'Ordered list of absolute image paths, one page each.'
        },
        output: { type: 'string', description: OUT },
        dpi: { type: 'integer', description: 'Assumed image resolution for page sizing. Default 200.' }
      },
      required: ['input', 'output'],
      additionalProperties: false
    },
    args: [
      { name: 'input', flag: '--input', type: 'array' },
      { name: 'output', flag: '--output', type: 'value' },
      { name: 'dpi', flag: '--dpi', type: 'value' }
    ]
  }
]

const TOOL_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]))

// Public tool descriptors (name/description/inputSchema only) for tools/list.
const TOOL_LIST = TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }))

function buildArgv(tool, a) {
  const argv = []
  for (const m of tool.args) {
    const v = a[m.name]
    if (v === undefined || v === null) continue
    if (m.type === 'array') {
      if (!Array.isArray(v)) continue
      for (const item of v) argv.push(m.flag, String(item))
    } else if (m.type === 'bool') {
      if (v === true) argv.push(m.flag)
    } else if (m.type === 'boolNo') {
      argv.push(v ? m.flag : m.noFlag)
    } else {
      argv.push(m.flag, String(v))
    }
  }
  return argv
}

/* ---------------------------- JSON-RPC plumbing ------------------------- */

function write(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n')
}

function reply(id, result) {
  write({ jsonrpc: '2.0', id, result })
}

function replyError(id, code, message) {
  write({ jsonrpc: '2.0', id, error: { code, message } })
}

async function handleToolCall(id, params) {
  const name = params?.name
  const args = params?.arguments ?? {}
  const tool = TOOL_BY_NAME.get(name)
  if (!tool) {
    reply(id, { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true })
    return
  }
  const result = await runEngine(tool.subcommand, buildArgv(tool, args))
  reply(id, {
    content: [{ type: 'text', text: JSON.stringify(result) }],
    isError: result && result.ok === false
  })
}

async function handle(msg) {
  const { id, method, params } = msg
  switch (method) {
    case 'initialize':
      reply(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: 'sam-pdf-studio', version: '1.0.0' }
      })
      return
    case 'notifications/initialized':
      return // notification, no reply
    case 'tools/list':
      reply(id, { tools: TOOL_LIST })
      return
    case 'tools/call':
      await handleToolCall(id, params)
      return
    case 'ping':
      reply(id, {})
      return
    default:
      // Notifications (no id) are ignored; requests get method-not-found.
      if (id !== undefined && id !== null) replyError(id, -32601, `Method not found: ${method}`)
      return
  }
}

/* ------------------------------- stdin loop ----------------------------- */

let buffer = ''
process.stdin.setEncoding('utf-8')
process.stdin.on('data', (chunk) => {
  buffer += chunk
  let idx
  while ((idx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, idx).trim()
    buffer = buffer.slice(idx + 1)
    if (!line) continue
    let msg
    try {
      msg = JSON.parse(line)
    } catch {
      continue // ignore non-JSON lines
    }
    void handle(msg)
  }
})
process.stdin.on('end', () => process.exit(0))
