---
name: webbrowser
description: Use CPSL's native webbrowser module for client-side web search, browsing, screenshots, and user handoff.
metadata:
  short-description: Native WebKit browser search and browsing through CPSL webbrowser primitives.
---

# Webbrowser

Use this skill when a task needs web search, page browsing, browser interaction, screenshots, or a handoff where the user needs to see or operate the browser.

Prefer `webbrowser` over raw HTTP when the page needs JavaScript, logged-in state, form interaction, or visual inspection.

## Background By Default

- Use the browser in the background by default. Do not call `webbrowser.show()` just because you opened, searched, clicked, typed, or inspected a page.
- Call `webbrowser.show(browser)` only when the user explicitly asks to see the browser, or when the task truly requires user handoff for authentication, consent, CAPTCHA, payment, permission prompts, or subjective visual confirmation.
- If a page can be inspected with `webbrowser.page()`, `webbrowser.eval()`, or `webbrowser.screenshot()` without interrupting the user, keep the browser hidden.

## Webbrowser vs HTTP

- Use `webbrowser` for search engines, normal websites, documentation sites, pages that need JavaScript, pages that may use cookies/login state, forms, visual inspection, screenshots, and user handoff.
- Use `http` for direct API calls, JSON endpoints, known static files, webhooks, or machine-readable resources where browser rendering and cookies are unnecessary.
- Do not use `http` as a replacement for browsing a site. If the user asks to search, browse, inspect, click, log in, or verify what a page shows, use `webbrowser`.
- Do not use `webbrowser` for simple API retrieval when `http` can fetch the exact machine-readable endpoint more directly.

## Defaults

- `webbrowser.create()` and `webbrowser.open()` use lean resource mode by default in CPSL.
- Lean mode avoids heavy resources such as images, media, and fonts for faster agent browsing.
- Use `{resource_mode="full"}` when visual resources are needed immediately.
- Use full mode from the first navigation for heavy JavaScript apps, login flows,
  social sites such as X, or any page that may treat missing images/fonts/media
  as a broken or non-browser session.
- `webbrowser.show(browser)` is only for explicit user handoff. The native host should show the browser UI and promote lean pages to full mode before displaying them.
- `webbrowser.type()` uses the host's natural typing path by default. In Herm, visible macOS pages use AppKit key events; iOS and offscreen pages use natural-paced WebKit input events. Use `{speed=4.0}` if you need to be explicit.

## Search And Browse

```lua
local opened = webbrowser.open("https://www.google.com/search?q=site%3Aexample.com+query", {
  wait_resources = true,
  resource_timeout = 3,
})
local browser = opened.browser

local page = webbrowser.page(browser, {
  fields = {"title", "url", "text", "actions"},
})
print(page.page and page.page.text or page.text or "")
```

If the response is short but references a saved JSON file, read the file from `/tmp` with `fs.read()`.

## Interaction

```lua
local page = webbrowser.page(browser)
webbrowser.click(browser, "a1")
webbrowser.type(browser, "a2", "search terms", {speed = 4.0})
webbrowser.submit(browser, "a3")
```

For coordinate-only controls:

```lua
webbrowser.click(browser, 320, 480)
webbrowser.scroll(browser, 500, 700, 0, 600)
```

## Screenshots

Write screenshots under `/tmp` unless the user asks for a persistent output path.

```lua
webbrowser.screenshot(browser, "/tmp/page.png", {
  resource_timeout = 5,
  capture_delay = 0.3,
})
```

## User Handoff

Do not show the browser during ordinary browsing. Show it only when the user asked to see it or when authentication, consent, CAPTCHA, payment, permission prompts, or subjective visual confirmation is required.

```lua
webbrowser.show(browser)
```

After the user acts, call `webbrowser.page(browser)` again to inspect the new page state.
