---
name: apple-context
description: Use CPSL calendar and location modules for user-approved Apple Calendar events and current device location.
metadata:
  short-description: Calendar and location through CPSL
---

# Apple Context

Use this skill when the user asks about their calendar, schedule, events, availability, travel time, local context, nearby places, weather at their current position, or any request that depends on the device's current location.

## How to load this skill

This file is markdown under `/skills/apple-context/SKILL.md`. Read it with:

```lua
print(fs.read("/skills/apple-context/SKILL.md"))
```

Do **not** `require("apple-context")`, `require("/skills/apple-context")`, `require("/skills/apple-context/SKILL.md")`, or any other require path. Skills are not Luau modules. CPSL `calendar` and `location` are **globals** (listed by `help()`); call them directly after you understand the APIs below.

## Permissions

- Prefer `calendar.help()` or `location.help()` when a signature is unclear.
- Calendar and location access states use `granted`, `denied`, and `undefined` through the `state` or `access` fields. If access is `undefined`, calling the relevant request/current function may prompt the user.
- If access is denied, stop using that capability and tell the user to enable access for Herm in iOS Settings or macOS System Settings. Do not repeatedly retry.
- Use only the minimum needed capability. Do not request calendar or location access unless it materially helps with the user's request.
- Print tables with `print(here)` (or `tostring(here)`); both show nested JSON. Do not conclude "unavailable" from top-level nils alone—coords and place live under `here.location`.

## Calendar

Use `calendar.status()` before reading or changing events when practical. If a calendar operation reports denied access, explain that Calendar access must be enabled in Settings.

```lua
local status = calendar.status()
if status.state == "undefined" then
  status = calendar.request_access("full")
end
```

List events with an explicit time range:

```lua
local events = calendar.events("2026-07-08T00:00:00Z", "2026-07-09T00:00:00Z", {limit = 50})
```

Create events only when the user asked you to add something or clearly approved it:

```lua
local event = calendar.create("Dentist", "2026-07-08T16:00:00Z", "2026-07-08T17:00:00Z", {
  location = "Main St"
})
```

## Location

Use `location.current()` for the current device location. It prompts if access is undefined and returns access metadata plus a nested `location` object with coordinates and, when reverse geocoding succeeds, human place fields (city, region, country, etc.).

```lua
local status = location.status()
print(status)

local here = location.current()
print(here)
-- Coordinates (always when a fix is available):
print(here.location.latitude, here.location.longitude)
-- Place names from Apple reverse geocoding (may be nil if geocode fails offline):
print(here.location.city, here.location.region, here.location.country)
print(here.location.formatted_address)
print(here.access) -- granted | denied | undefined
```

Prefer answering with city/region/country when present; still keep latitude/longitude available if the user wants precision. If `here.access` is `denied` or the call errors with a permission message, tell the user to enable Location for Herm in Settings.

Treat location as sensitive. Do not print precise coordinates unless the user needs them or asks for them; prefer city-level place fields for ordinary answers.
