---
name: beautiful-pdfs
description: Build polished PDF documents by composing semantic HTML/CSS and rendering HTML to PDF.
metadata:
  short-description: Build polished PDFs with HTML and CSS
---

# Beautiful PDFs

Use this skill when the user asks for a PDF, printable report, invoice, brief, handout, form, one-pager, or visual document.

## Workflow

1. Create semantic HTML first. Use real document structure: headings, sections, tables, figures, captions, footers, and page-break rules.
2. Put presentation in CSS. Prefer restrained typography, clear spacing, durable contrast, and print-safe colors. Avoid huge hero layouts unless the user explicitly asks for a cover page.
3. Write source HTML to a temporary or hidden build path unless the user explicitly asks for editable source files.
4. Render HTML to PDF with the available document module. Start by checking `help()` and `doc.help()` if the exact API is not already visible in context.
5. Prefer `doc.renderFile({source="/tmp/report.html", target="/home/herm/report.pdf"})` for saved HTML-to-PDF output. It detects `html -> pdf` from the file extensions.
6. Inspect the resulting PDF metadata or page count when practical before telling the user it is ready.

## HTML Guidance

- [print.css](print.css) contains a compact print-oriented baseline you can read and adapt when useful.
- Include `<!doctype html>`, `<meta charset="utf-8">`, and a viewport meta tag.
- Add `@page` rules for size and margins. Use letter size unless the user asks for another page size.
- Add deliberate page breaks for multipage documents. Use `.page` for fixed page-sized sections, `break-before: page` for major section starts, and `break-after: page` for cover/title pages.
- Use CSS variables for palette and spacing so revisions are easy.
- Keep cards and panels print-friendly: subtle borders, no heavy shadows, no fragile fixed viewport heights.
- Use `break-inside: avoid` only on content that must stay together, such as figures, callouts, short tables, signatures, and compact sections. Do not apply it to long sections or large tables that may need to span pages.

## Output

Save the PDF under `/home/herm` unless the user requested another path. If the user asked only for a PDF, expose only the PDF in the final response; do not place or present source HTML next to it. Keep source files in `/tmp` or a hidden build directory unless the user asks for editable source files.
