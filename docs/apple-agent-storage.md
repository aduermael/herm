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
