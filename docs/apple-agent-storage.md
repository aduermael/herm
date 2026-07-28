# Apple Agent Storage

The Swift agent stores durable state in two append-only JSONL files:

- `conversations.jsonl` contains conversation, node, tag, and metadata mutations.
- `traces.jsonl` contains detailed provider requests/responses, tool calls, web
  visits, and errors. Trace entries are not loaded to render a conversation.

At launch, the app first tries the iCloud ubiquity container and stores the logs
under `Documents/Herm`. If iCloud is unavailable, it falls back to Application
Support. Each write encodes one complete JSON value on one line, appends it, and
synchronizes the file. Normal writes never load and rewrite the existing log.

The debug export is different by design: it loads the relevant JSONL entries and
creates a documented, pretty-printed JSON object with the reconstructed
conversation, chronological source events, chronological trace events, and `jq`
examples. This keeps the live format cheap to append while making exported data
easy for humans and analysis tools to inspect partially.

## Log and export shape

Every JSONL entry has `schemaVersion`, `id`, `timestamp`, and `kind`; timestamps
use ISO-8601 UTC with fractional seconds so rapid mutations remain ordered.
Conversation entries additionally identify `conversationID` when the event is
conversation-scoped. Their kinds are `conversation.created`, `nodes.appended`,
`node.body_updated`, conversation metadata mutations, and tag mutations. The
event-specific value is stored under the matching field such as `conversation`,
`nodes`, `body`, `model`, `flag`, `title`, `tag`, or `tagIDs`.

Trace kinds are `provider.request`, `provider.response`, `tool.invocation`,
`web.visit`, and `error`. Their detailed values are under `providerRequest`,
`providerResponse`, `toolInvocation`, `webVisit`, or `message`. Provider request
entries include the exact replay messages and tool schemas; sandbox trace output
is not shortened for presentation.

An exported JSON object has this stable top-level shape:

```text
format, schemaVersion, generatedAt, documentation,
conversation, tags, conversationEvents, traceEvents
```

Useful partial reads include:

```sh
jq '.conversation.summary' export.json
jq '.conversation.nodes[] | {sequence, role, title, body}' export.json
jq '.traceEvents[] | select(.kind == "tool.invocation") | .toolInvocation' export.json
```

This is an iCloud file-container prototype, not a multi-writer sync system.
Concurrent appends from multiple devices and log compaction remain future work.

Practical implications for this prototype:

- Keep every JSONL entry independently decodable and versioned.
- Ignore and discard only an incomplete final line, which can be left by process
  termination; corruption in a completed line is an error.
- Treat concurrent edits from multiple devices as a future storage problem, not
  something this prototype fully solves.
- Keep the node model independent of the log replay details so persistence can
  change later without changing the agent loop.

## Agent files

The Apple app keeps its CPSL filesystem under Application Support. Durable
agent-created files belong in `/home/herm`; temporary work belongs in `/tmp`.
At app launch, files under `/tmp` older than 24 hours are removed and empty
temporary directories are pruned.

Files added through the composer are copied to
`/attachments/<conversation-id>/`. A draft receives its final conversation ID
before its first message so files never need a staging path. The attachment
mount is read-only to CPSL, remains available for later turns in the same
conversation, and is removed when the conversation is deleted.

The composer supports Files and Photo Library on Apple platforms, plus Camera
on iOS when a camera is available.

The native browser bridge resolves CPSL paths before supplying files to a
website file input; web content never receives or resolves a CPSL path itself.
Browser downloads are saved under `/tmp/downloads` and reported back as virtual
paths.

Connected iCloud Drive folders are additional CPSL file mounts. They do not
change the agent's HTTP policy, native browser availability, or document
rendering capability. The agent is instructed to treat mounted content as
personal data and access it only when the task calls for it.

EventKit exposes an event URL and notes but no public file-attachment API. Herm
therefore provides `calendar.attach(event_id, paths)` as an app-managed layer:
it copies files under `/home/herm/calendar-attachments`, records their virtual
paths in a delimited event-notes block, returns them from `calendar.get` and
`calendar.events`, and shows them as openable chips in Herm's Calendar overlay.
Deleting the event through CPSL removes those copies. They are not native
Calendar.app attachments, and the copies live in Herm's local app storage rather
than syncing as files through Calendar. They should not be described as native
attachments. See Apple's
[`EKCalendarItem`](https://developer.apple.com/documentation/eventkit/ekcalendaritem)
API surface.
