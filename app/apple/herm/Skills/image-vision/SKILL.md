---
name: image-vision
description: Inspect attached or local images and visually analyze PDFs with CPSL vision. Use for photos, screenshots, scans, charts, diagrams, OCR, handwriting, UI inspection, or any task that depends on pixels, layout, or other non-structural page content.
metadata:
  short-description: Inspect images and PDFs with CPSL vision
---

# Image Vision

Use CPSL's `doc` module with the exact attachment or local path. Do not guess or rewrite the path.

## Read One File

Start with the simplest form:

```lua
local result = doc.read("/attachments/conversation-id/photo.jpeg")
print(result)
```

Images and PDFs default to vision when the vision callback is available. The built-in prompt extracts the document as structured Markdown and describes images, charts, diagrams, and other visual elements. This default is appropriate for most requests. Other supported document types default to structural extraction.

Treat the returned text as the visual model's analysis, then answer the user's question rather than merely repeating the extraction.

Supported visual inputs include PDF, PNG, JPEG, WebP, and GIF files.

## Read Multiple Files

Issue all asynchronous reads before awaiting any result so vision requests can run in parallel:

```lua
local front = doc.readAsync("/attachments/conversation-id/front.jpeg")
local back = doc.readAsync("/attachments/conversation-id/back.jpeg")

local frontText = front:await()
local backText = back:await()
print(frontText)
print(backText)
```

## Customize The Prompt

Set `query` only when the user needs a narrower analysis, special output format, or more detail than the default extraction:

```lua
local result = doc.read("/attachments/conversation-id/chart.jpeg", {
  query = "Extract the chart's title, axis labels, legend, and data values as a Markdown table."
})
print(result)
```

Preserve the user's request in the query. Set `mode = "vision"` when an explicit visual-mode override is useful:

```lua
local result = doc.read("/attachments/conversation-id/report.pdf", {
  mode = "vision",
  query = "Describe the page layout and all diagrams."
})
print(result)
```

Use `mode = "structural"` for a PDF when machine-readable text matters and visual interpretation is unnecessary. When both appearance and exact embedded text matter, run vision and structural reads separately and distinguish their results. Do not substitute structural extraction for requested visual analysis.

## Failure Handling

- Treat `vision callback ... not available`, provider configuration, authentication, and unsupported-model errors as authoritative. Report the limitation and stop after that failure.
- Do not retry through image resizing, EXIF inspection, color or pixel sampling, ASCII rendering, browser upload, network services, or invented OCR APIs.
- Do not silently fall back to structural mode when the task requires seeing pixels, layout, handwriting, charts, or diagrams.
- Never claim to have seen or analyzed a file unless the vision read succeeded.
