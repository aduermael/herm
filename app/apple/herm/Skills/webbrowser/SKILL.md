---
name: webbrowser
description: Use CPSL's native webbrowser module for web search, browsing, authenticated website interaction, forms, file uploads and downloads, screenshots, and user handoff.
metadata:
  short-description: Native WebKit browsing and authenticated website interaction through CPSL primitives.
---

# Webbrowser

Use this skill when a task needs web search, page browsing, browser interaction, screenshots, or a handoff where the user needs to see or operate the browser.

Prefer `webbrowser` over raw HTTP when the page needs JavaScript, logged-in state, form interaction, or visual inspection.

A missing dedicated integration for a service is not a reason to stop when its
website can perform the requested action. Browser sessions use persistent
WebKit state and may already be signed in. When the user explicitly asks for a
specific action, use the normal website flow on their behalf before reporting
that it cannot be completed.

## Background By Default

- Use the browser in the background by default. Do not call `webbrowser.show()` just because you opened, searched, clicked, typed, or inspected a page.
- Call `webbrowser.show(browser)` only when the user explicitly asks to see the browser, or when the task truly requires user handoff for authentication, consent, CAPTCHA, payment, permission prompts, or subjective visual confirmation.
- If a page can be inspected with `webbrowser.page()`, `webbrowser.eval()`, or `webbrowser.screenshot()` without interrupting the user, keep the browser hidden.

## Sub-Agent First For Research

- For broad web research, multi-page comparison, repeated search result triage, or anything likely to produce a lot of page text, delegate the browsing task to an `agent` sub-agent in explore mode.
- Keep the main conversation context focused on the user's request, the sub-agent task, and the concise result. Do not stream raw search result pages, long page dumps, or every visited URL into the main context unless the user asks for that detail.
- Use the main agent directly only for small, targeted browsing where one or two page inspections are enough.

## Webbrowser vs HTTP

- Use `webbrowser` for search engines, normal websites, documentation sites, pages that need JavaScript, pages that may use cookies/login state, forms, visual inspection, screenshots, and user handoff.
- Use `http` for direct API calls, JSON endpoints, known static files, webhooks, or machine-readable resources where browser rendering and cookies are unnecessary.
- Do not use `http` as a replacement for browsing a site. If the user asks to search, browse, inspect, click, log in, or verify what a page shows, use `webbrowser`.
- Do not use `webbrowser` for simple API retrieval when `http` can fetch the exact machine-readable endpoint more directly.

## Defaults

- `webbrowser.create()` and `webbrowser.open()` use lean resource mode by default in CPSL.
- Lean mode avoids heavy resources such as images, media, and fonts for faster agent browsing.
- Herm browser sessions default to a desktop-sized viewport, currently 1200px
  wide by default. Do not resize a browser to phone dimensions unless the user
  explicitly needs mobile rendering.
- Use `{resource_mode="full"}` when visual resources are needed immediately.
- Use full mode from the first navigation for heavy JavaScript apps, login flows,
  social sites, and any account action involving a private message, form, or
  file transfer. Do not switch modes by reloading after preparing a draft.
- `webbrowser.show(browser)` is only for explicit user handoff. The native host should show the browser UI and promote lean pages to full mode before displaying them.
- `webbrowser.type()` uses `{backend="auto"}` by default. Background pages remain attached to an offscreen native host. macOS uses AppKit key events. iOS uses a scene-associated window that cannot become key, temporarily sets `inputmode="none"`, and attempts WebKit's `UIKeyInput` responder without activating the software keyboard. If WebKit cannot expose that responder before committing text, it falls back once to a whole-string DOM edit. Read `result.typing.backendUsed`, `nativeAttempted`, `committedCharacterCount`, `fallbackReason`, `interruptionReason`, and host diagnostics instead of assuming which path ran. Use `{speed=4.0}` if you need to be explicit.

## Search And Browse

```lua
local opened = webbrowser.open("https://www.google.com/search?q=site%3Aexample.com+query")
local browser = opened.browser

local page = webbrowser.page(browser, {
  fields = {"title", "url", "text", "actions"},
})
print(page.page and page.page.text or page.text or "")
```

Do not add `wait_resources` to initial navigation as a precaution. Use `webbrowser.wait_resources(browser, {resource_timeout=3})` or `webbrowser.page(browser, {wait_resources=true, resource_timeout=3})` after opening when scripts, styles, images, or fetches matter.

If the response is short but references a saved JSON file, read the file from `/tmp` with `fs.read()`.

## Interaction

```lua
local result = webbrowser.page(browser)
local page = result.page
webbrowser.click(browser, "a1")
webbrowser.type(browser, "a2", "search terms", {speed = 4.0})
webbrowser.key_press(browser, "a2", "Enter")
```

Browser calls return a result wrapper. Read page state from `result.page`
(`result.page.url`, `result.page.actions`, `result.page.dialogs`), not from the
top-level result.

`webbrowser.fill()` replaces existing text. `webbrowser.type()` focuses and
appends naturally paced text; it does not clear first. Use
`webbrowser.key_press(browser, action, "Enter")` for Enter—never
`webbrowser.type(..., "\n")`.

`key_press()` accepts one exact control-key name such as `Enter`, `Escape`,
`Tab`, `Backspace`, or an arrow key. Do not invent strings such as
`Control+Enter`. On iOS the result includes `result.keyPress.pageConsumed`,
which says whether a page handler prevented the dispatched key; verify the
actual postcondition because event delivery alone does not prove submission.

For text entry, use one current textbox action and one `type()` or `fill()`
call. Verify `result.typing.target` or `result.target` before an irreversible
submission. Do not stack retries through custom JavaScript
`beforeinput`, paste, `execCommand`, or synthetic keyboard events; reactive
editors may process more than one path even when an immediate DOM check looks
empty. If entry does not verify, refresh the page actions and make at most one
clean retry with the current textbox handle.

For submission, inspect the returned page and draft once. If the intended
state change did not occur, refresh the actions and make at most one clean
retry. Do not probe modifier combinations, repeatedly submit the same form, or
reload a prepared draft while searching for another submission mechanism.

Once a submission is confirmed, do not send a corrective follow-up unless the
user explicitly asks. Report the actual result, including every side effect.

## File Uploads

Use `webbrowser.upload()` when one visible action directly opens a file chooser.
Pass that action and one CPSL path or an array of CPSL paths. The host arms a
one-shot native file-picker handler, clicks the action, and gives WebKit the
resolved on-device file URLs when the page opens its chooser.

```lua
webbrowser.upload(browser, "a4", {
  "/attachments/conversation-id/photo.jpg",
  "/home/herm/report.pdf",
})
```

When uploading requires multiple normal interactions—for example, opening an
attachment menu and then choosing "Upload a File"—open and inspect the menu
first, then call `upload()` on the current final menu item. This keeps chooser
arming and the final click atomic, and only succeeds after WebKit asks the host
for files.

```lua
local opened = webbrowser.click(browser, "a4") -- opens the site's attachment menu
local page = opened.page -- find the current Upload action here
local result = webbrowser.upload(browser, "a9", {
  "/attachments/conversation-id/photo.jpg",
})
assert(result.upload.state == "selected")
```

After `upload.state == "selected"`, keep that page and draft intact until it is
submitted or deliberately cancelled. Do not navigate, reload, replace the
browser, or re-upload the same file while troubleshooting a later step.

Use `arm_upload()` only when the final chooser-opening interaction cannot be
expressed as one current action. It is single-use and expires after 60 seconds.
The following `click()` result includes `result.upload.state`: `selected` means
the native chooser consumed the paths; `armed` means no chooser opened yet.

Typing and key results include `browserHost`, `typing`, and `keyPress`
diagnostics. Interaction diagnostics include the non-key host and main-window
identities, keyboard notification frames, and privacy-safe focus/input event
metadata (event type and text lengths, never the typed text). Upload results
include the chooser mode, action, timestamps, host-at-arm state, selection
count, and failure state. Preserve these fields when reporting an unexpected
interaction so the session trace remains useful.

Use the website's existing controls. Never unhide, relabel, restyle, or inject
file inputs or proxy buttons. Do not invent host paths or use JavaScript to
read local files. If normal site interaction cannot open the chooser, report
the limitation instead of modifying the page to manufacture an upload target.

Call `webbrowser.page()` after the upload if the site needs time to render a
preview, then submit or send the form normally.

If `webbrowser.upload()` is unavailable despite being documented, stop and
report that the browser runtime is out of sync. Do not work around it by
reading a binary file into JavaScript, extracting browser credentials, or
calling a site's private API.

Never extract, print, copy, or reuse authentication tokens, cookies, or other
session secrets from browser storage or page JavaScript. Keep authenticated
actions inside the normal browser flow; use `webbrowser.show()` for user
handoff when that flow cannot be completed safely.

## Downloads

Downloads triggered by browser links and buttons are saved under
`/tmp/downloads`. A completed download may be returned as `result.download` by
`webbrowser.click()`, and `webbrowser.page()` includes recent paths in
`page.downloads`. If the site prepares a download asynchronously, inspect the
page again before assuming it failed.

Use `http` instead when the task starts from an exact static-file URL and does
not need browser cookies, JavaScript, or a button click.

For coordinate-only controls:

```lua
webbrowser.click(browser, 320, 480)
webbrowser.scroll(browser, 500, 700, 0, 600)
```

`webbrowser.eval()` returns a table. Read the JavaScript result from `.value`:

```lua
local title = webbrowser.eval(browser, "return document.title", {function_body=true}).value
```

Objects and arrays in `.value` are JSON strings. Decode them before reading
fields:

```lua
local result = webbrowser.eval(browser, "return {x: 10, y: 20}", {function_body=true})
local point = json.decode(result.value)
```

Return strings, numbers, booleans, or JSON-serializable values from eval. For
DOM nodes or framework objects, extract the fields you need and return a plain
table/object or `JSON.stringify(...)`.

## Screenshots

Write screenshots under `/tmp` unless the user asks for a persistent output path.
Screenshots are currently saved artifacts, not visual input to the agent. Use
`result.page.dialogs`, page text, and page actions to inspect browser state; do
not claim to have visually analyzed a saved screenshot.

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

After every unexpected interaction result, inspect the returned page before
continuing. Treat entries in `result.page.dialogs` as blocking UI that must be
handled or reported. Action IDs identify a specific element; if one becomes
stale, get the latest page instead of guessing or substituting another control.
