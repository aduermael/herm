---
name: beautiful-pdfs
description: Build polished PDF documents by composing semantic HTML/CSS and rendering HTML to PDF inside the CPSL sandbox.
metadata:
  short-description: Build polished PDFs with HTML and CSS
---

# Beautiful PDFs

Use this skill when the user asks for a PDF, printable report, invoice, brief, handout, form, one-pager, or visual document.

## Workflow

1. Create semantic HTML first. Use real document structure: headings, sections, tables, figures, captions, footers, and page-break rules.
2. Put presentation in CSS. Prefer restrained typography, clear spacing, durable contrast, and print-safe colors. Avoid huge hero layouts unless the user explicitly asks for a cover page.
3. Write the HTML to a durable path such as `/home/herm/report.html`.
4. Render HTML to PDF with CPSL's document module. Start by checking `help()` and `doc.help()` if the exact API is not already visible in context.
5. Prefer `doc.renderFile({source="/home/herm/report.html", target="/home/herm/report.pdf"})` for complete files. It detects `html -> pdf` from the file extensions.
6. Inspect the resulting PDF metadata or page count when practical before telling the user it is ready.

## HTML Guidance

- `/skills/beautiful-pdfs/print.css` contains a compact print-oriented baseline you can read and adapt when useful.
- Include `<!doctype html>`, `<meta charset="utf-8">`, and a viewport meta tag.
- Add `@page` rules for size and margins. Use letter size unless the user asks for another page size.
- Use CSS variables for palette and spacing so revisions are easy.
- Keep cards and panels print-friendly: subtle borders, no heavy shadows, no fragile fixed viewport heights.
- For multipage documents, use `break-inside: avoid` on tables, figures, and important sections.

## Output

Save the PDF under `/home/herm` unless the user requested another path. If you also create the source HTML, leave it next to the PDF so later edits are easy.
