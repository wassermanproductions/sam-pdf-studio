# sam-pdf-studio-mcp

MCP (Model Context Protocol) stdio bridge for **[Sam PDF Studio](https://github.com/wassermanproductions/sam-pdf-studio)** — a full-featured PDF editor. This server runs Sam PDF Studio's PyMuPDF engine **headlessly**, so any MCP agent can merge, split, rotate, redact, OCR, compress, password-protect, and convert PDFs directly on file paths — no GUI, no window, no clicking.

Zero dependencies. Node ≥ 18. One file.

## What it is

Sam PDF Studio ships a self-contained Python engine (`pdf_engine.py`) with its own virtual environment. This bridge is a thin wrapper that spawns that engine as a subprocess for each tool call and returns the JSON it prints. Every operation reads an **input** path and writes a **new output** path — your source files are never modified in place.

## Requirements

1. **Install or build Sam PDF Studio** from the [Sam PDF Studio repo](https://github.com/wassermanproductions/sam-pdf-studio). Installing it provisions the engine virtual environment (with PyMuPDF, pypdf, pdf2docx, ocrmypdf, and the OCR/compression binaries) that this bridge drives.
2. That's it — there is nothing to configure. The bridge auto-discovers:
   - the engine Python at `~/Library/Application Support/SamPDFStudio/engine-venv/bin/python3`, and
   - the engine script `pdf_engine.py` inside the installed app (or a local build).

   Override either with the `SAMPDF_ENGINE_PYTHON` and `SAMPDF_ENGINE_SCRIPT` environment variables if your install lives elsewhere. Run the `health` tool first to confirm the engine and all its dependencies are present.

## Connect

### Hermes

Add to `~/.hermes/config.yaml` (or install from the Hermes MCP catalog once listed):

```yaml
mcp_servers:
  sam-pdf-studio:
    command: "node"
    args: ["/absolute/path/to/sam-pdf-studio-mcp/sam-pdf-studio-mcp.mjs"]
```

### Claude Code

```bash
claude mcp add sam-pdf-studio -- node /absolute/path/to/sam-pdf-studio-mcp/sam-pdf-studio-mcp.mjs
```

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.sam-pdf-studio]
command = "node"
args = ["/absolute/path/to/sam-pdf-studio-mcp/sam-pdf-studio-mcp.mjs"]
```

### Any MCP client (generic stdio config)

```json
{ "mcpServers": { "sam-pdf-studio": { "command": "node", "args": ["/absolute/path/to/sam-pdf-studio-mcp/sam-pdf-studio-mcp.mjs"] } } }
```

## Tools (23)

Call `health` first to confirm the engine is ready. Every tool takes an absolute `input` path and writes to a new `output` path (or `output_dir`); coordinates are in PDF points and page numbers are 1-based.

| Tool | What it does |
| --- | --- |
| `health` | Verify the engine and all dependencies are installed. |
| `metadata` | Read page count and document metadata. |
| `merge_pdfs` | Concatenate several PDFs into one. |
| `split_pdf` | Split a PDF into per-page files in a directory. |
| `extract_pages` | Keep only a selection of pages. |
| `delete_pages` | Remove a selection of pages. |
| `rotate_pages` | Rotate pages by 90/180/270°. |
| `replace_text` | Find and replace literal text, matching style. |
| `redact_text` | Permanently black out and remove text. |
| `add_text` | Draw text at a position on a page. |
| `add_image` | Place an image on a page. |
| `add_link` | Add a clickable URL hyperlink. |
| `compress_pdf` | Reduce file size. |
| `add_page_numbers` | Stamp page numbers. |
| `resize_pages` | Scale pages to a new size. |
| `set_password` | Encrypt with an open password. |
| `ocr` | Add a searchable text layer to scans. |
| `export_docx` | Convert to editable Word `.docx`. |
| `export_xlsx` | Extract tables to Excel `.xlsx`. |
| `export_pptx` | Convert pages to PowerPoint slides. |
| `export_text` | Extract text to `.txt` / Markdown / HTML. |
| `export_images` | Render pages to PNG/JPG. |
| `images_to_pdf` | Combine images into a PDF. |

## Security

This bridge runs **only** the local, vetted Sam PDF Studio engine on **local files** you point it at. It opens no network connections, binds no ports, and passes no credentials. It spawns the engine Python resolved from your Sam PDF Studio install (or your explicit `SAMPDF_ENGINE_*` overrides) and nothing else. Output is always written to a new path, so inputs are never mutated.

## License & credit

Apache-2.0 — see [LICENSE](LICENSE). Per the [NOTICE](NOTICE) file, use, forks, and redistribution must credit **Sam Wasserman ([wassermanproductions.com](https://wassermanproductions.com))**.
