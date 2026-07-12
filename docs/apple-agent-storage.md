# Apple Agent Storage

The Swift agent stores conversations in a local SQLite database with node-shaped
conversation history. At launch, the app first tries the iCloud ubiquity
container and stores the database under `Documents/Herm/conversations.sqlite`.
If iCloud is unavailable, it falls back to Application Support.

This is an iCloud file-container prototype, not Apple's standard robust
structured-data sync design. It can make a SQLite file available through the
shared iCloud documents container, but SQLite is still a single local database
file and iCloud file syncing does not provide record-level merge semantics. For
production-quality multi-device structured data sync, the expected Apple stack is
CloudKit-backed persistence, such as Core Data or SwiftData with CloudKit.

Practical implications for this prototype:

- Keep SQLite in rollback-journal mode, not WAL, so the database is not split
  across multiple live files.
- Use short transactions and `BEGIN IMMEDIATE` so local writes are serialized.
- Treat concurrent edits from multiple devices as a future CloudKit migration
  problem, not something this file-sync prototype fully solves.
- Keep the node schema independent of SQLite details so the persistence layer can
  move to CloudKit-backed storage later without changing the agent loop.

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
