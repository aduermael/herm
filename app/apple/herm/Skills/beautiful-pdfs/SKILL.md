---
name: beautiful-pdfs
description: Build polished PDF documents by composing semantic HTML/CSS and rendering HTML to PDF.
metadata:
  short-description: Build polished PDFs with HTML and CSS
---

# Beautiful PDFs

Use this skill when the user asks for a PDF, printable report, invoice, brief, handout, form, one-pager, or visual document.

## Workflow

1. Use the available Luau globals directly. Do not call `require`; use `fs.read`, `fs.write`, and `doc.renderFile`.
2. Confirm HTML-to-PDF rendering is available before investing in a long document. If unsure, create a tiny HTML file in `/tmp` and run:
   ```lua
   fs.write("/tmp/pdf-smoke.html", "<!doctype html><meta charset=\"utf-8\"><h1>PDF smoke test</h1>")
   doc.renderFile({source="/tmp/pdf-smoke.html", target="/tmp/pdf-smoke.pdf"})
   print(fs.exists("/tmp/pdf-smoke.pdf"))
   ```
3. If rendering reports `platform not supported`, policy denial, or another capability error, stop PDF-generation work. Tell the user that PDF creation is unavailable in this session; do not try image-based PDF, font fetching, network downloads, package installs, browser printing, external renderers, or OS tools.
4. Create semantic HTML. Use real document structure: headings, sections, tables, figures, captions, footers, and page-break rules.
5. Put presentation in CSS. Prefer restrained typography, clear spacing, durable contrast, and print-safe colors. Avoid huge hero layouts unless the user explicitly asks for a cover page.
6. Write source HTML to a temporary or hidden build path unless the user explicitly asks for editable source files.
7. Render HTML to PDF with the available document module. Start by checking `help()` and `doc.help()` if the exact API is not already visible in context.
8. Prefer `doc.renderFile({source="/tmp/report.html", target="/home/herm/report.pdf"})` for saved HTML-to-PDF output. It detects `html -> pdf` from the file extensions.
9. Inspect the resulting PDF metadata or page count when practical before telling the user it is ready.

## Luau Snippets

Read and adapt the bundled print baseline when useful:

```lua
local css = fs.read("/skills/beautiful-pdfs/print.css")
```

Build source HTML in `/tmp` so the user only sees the PDF unless they ask for source files:

```lua
local css = fs.read("/skills/beautiful-pdfs/print.css")
local html = [[
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>]] .. css .. [[</style>
</head>
<body>
  <main class="page">
    <h1>Document Title</h1>
    <p>Replace this with the user's content.</p>
  </main>
</body>
</html>
]]

fs.write("/tmp/report.html", html)
```

Render the temporary HTML to the durable PDF path and verify that it exists:

```lua
doc.renderFile({source="/tmp/report.html", target="/home/herm/report.pdf"})
print(fs.exists("/home/herm/report.pdf"))
```

## HTML Guidance

- [print.css](print.css) contains a compact print-oriented baseline you can read and adapt when useful.
- Include `<!doctype html>`, `<meta charset="utf-8">`, and a viewport meta tag.
- Add `@page` rules for size and margins. Use letter size unless the user asks for another page size.
- Add deliberate page breaks for multipage documents. Use `.page` for fixed page-sized sections, `break-before: page` for major section starts, and `break-after: page` for cover/title pages.
- Use CSS variables for palette and spacing so revisions are easy.
- Keep cards and panels print-friendly: subtle borders, no heavy shadows, no fragile fixed viewport heights.
- Use `break-inside: avoid` only on content that must stay together, such as figures, callouts, short tables, signatures, and compact sections. Do not apply it to long sections or large tables that may need to span pages.

## Output

When rendering succeeds, save the PDF under `/home/herm` unless the user requested another path. If the user asked only for a PDF, expose only the PDF in the final response; do not place or present source HTML next to it. Keep source files in `/tmp` or a hidden build directory unless the user asks for editable source files.

When rendering fails, do not claim a PDF was created. Preserve polished HTML only if useful, and say clearly that no PDF was produced in this session.
