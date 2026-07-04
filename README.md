# Osmo

Cross-platform relationship intelligence for Mac. Reads your own conversations
locally, builds one shared memory of each person across platforms, and — grounded
in a communication-psychology engine — drafts what to say to move each
relationship toward a goal and tone you set. Local-first; a Cluely-style overlay
lives inside your messaging apps; a morning approve-queue is the daily ritual.

Full build plan: `~/.claude/plans/write-a-ralph-loop-keen-quilt.md`.

## Status — P0 foundation (complete)

`OsmoCore` (this Swift package) is the local-first engine. P0 delivered and tested:

- **Canonical sync-ready schema** — `Message`/`Thread`/`Contact` with UUID PK,
  `updatedAt`, per-device monotonic `deviceSeq`, and soft-delete tombstones, so
  the future P2 E2EE cloud sync is a drop-in. IDs are **deterministic** (UUID v5
  from each platform's stable GUID) so re-import and a second Mac converge on the
  same rows.
- **Encrypted local store** — GRDB + FTS5 unified full-text search across every
  platform's messages. Whole-DB SQLCipher encryption is isolated to a single
  seam (`OsmoDatabase.open`) and is the next storage slice (see below).
- **iMessage reference reader** — read-only `chat.db` reader + normalizer,
  handling Cocoa-nanosecond timestamps, read receipts (`date_read` → texting
  status as *fact*), from-me attribution, group vs 1:1, and the macOS-26 Tahoe
  `any;-;` GUID change (keyed on `chat_identifier`, not the service-prefixed GUID).
- **Reused brain** — the psychology/memory/suggestion engine is ported unchanged
  from RegisterKit (builds + 391 tests pass on macOS): `CommunicationCraft`,
  `PromptBuilder`, `RelationshipMemory`, the preference bandit, `ContentPolicy`,
  `ConvoScan`. The P0 gate test proves imported data → RegisterKit engine →
  grounded reply prompt.

Run: `swift test` (15 tests).

## Known follow-ups (tracked in the plan)
- **SQLCipher swap** (P0.3b): replace vanilla GRDB with a SQLCipher-backed build
  at `OsmoDatabase.open`; passphrase from Keychain; verify the DB file is opaque
  at rest. Isolated to one file by design.
- **RegisterKit dependency** is currently referenced by an absolute local path in
  `Package.swift`. Vendor it (submodule or monorepo copy) before this repo leaves
  the machine.
- **attributedBody** messages (rich content stored in the typedstream blob, no
  `text` column) are skipped by the reader for now; parse them in P1.
