# Andesite — integrated local backend (experimental)

A Swift 6 headless Markdown vault backend. **Local CLI ingestion, search,
per-file recovery snapshots, tombstones and conservative external moves work
end-to-end. HTTP serving, authentication and sync are not implemented.**
Use temporary test vaults, not production notes; filesystem/power-loss
qualification and full v1 recovery remain outstanding.

## Build and exercise

Requires Swift 6.2+, SQLite >= 3.35 with FTS5 and development headers/pkg-config.
Run `swift build` and `swift test`. Dependencies remain pinned in SwiftPM.

Create separate, pre-existing vault and state directories. State must be owned
by your OS user and mode 0700. Supply absolute physical paths: no symlink in any
ancestor (on macOS, use `/private/tmp`, not `/tmp`). Ancestors must not be
writable by other users, except shared sticky directories. Vault and state must
not overlap. Only one vault is configured per state directory.

```sh
sample=$(mktemp -d /private/tmp/andesite-demo.XXXXXX) # Linux: /tmp instead
mkdir "$sample/vault" "$sample/state"
chmod 700 "$sample/state"
printf '# Example\ninitial phrase\n' > "$sample/vault/note.md"
.build/debug/andesite-server init --vault "$sample/vault" --state "$sample/state"
.build/debug/andesite-server search --vault "$sample/vault" --state "$sample/state" 'initial phrase'
printf '# Revised\nreplacement phrase\n' > "$sample/vault/note.md"
.build/debug/andesite-server reconcile --vault "$sample/vault" --state "$sample/state"
.build/debug/andesite-server status --vault "$sample/vault" --state "$sample/state"
```

`init` is an idempotent open + reconcile, not a reset. `status` checks stored
objects and reports catalog counts; it does **not** scan current files. Each
open marks the vault `scanRequired`; `reconcile` produces `ready` or
`quarantined`, and failures produce `scanFailed`. Search always reconciles
first, so an unsuccessful scan fails search rather than presenting an old
index as current. Invalid UTF-8 Markdown is retained as an incident object;
other valid files remain searchable. CLI prints entry IDs and heading titles.
No arguments/unknown commands fail closed; no command opens a network listener.

## What is integrated

`VaultRuntime` owns configuration validation, exclusive process lock, SQLite
migration/connection, immutable objects, stable observations, external capture,
Markdown analysis and revision-aware FTS. It is a synchronous, non-Sendable
owner; call from one blocking executor, never an NIO event loop. Throwing
`shutdown()` flushes pending observed heads, closes resources, then releases
ownership (even if flushing fails). Call it explicitly and handle its errors;
`deinit` only releases resources. Startup errors release resources too.
A future HTTP layer can use this coordinator behind serialized blocking offload.

* A no-follow, descriptor-relative recursive scan discovers case-insensitive
  `.md` files. Attachments are not ingested in this milestone. Symlinks, special
  files, hard links, mount crossings, unreadable/invalid names and portable
  namespace collisions abort the scan, even for non-Markdown entries.
* Paths retain original spelling; portability comparison uses Unicode NFC plus
  Foundation Unicode case folding (POSIX locale). Unicode filenames work;
  invalid UTF-8, controls, traversal, backslashes and `.andesite*` scan names
  are rejected. This is not yet a version-pinned cross-platform Unicode table.
* Files are canonical and never rewritten. Two bounded byte/metadata reads
  capture observations. New/changed bytes become durable SHA-256 objects,
  random stable document IDs, parent-linked revisions and ordered changes.
  Unchanged bytes do not allocate revisions or change sequences; a verified
  path change does allocate a move revision.
* Invalid UTF-8 is stored separately without replacing a good head/history;
  repeated identical open incidents are deduplicated. Corrected valid content
  resolves incidents, even if it matches the previous head.
* Verified immutable revision bytes feed the existing basic swift-markdown
  extractor and FTS. Search is vault-scoped, literal-phrase, bounded, current-head
  checked, and excludes open incidents. It currently indexes raw Markdown with
  a heading title, not complete v1 extracted document text.

## File recovery snapshots

Snapshots are complete files, not diffs. Metadata is in the private state's
SQLite catalog and contents reference the existing immutable SHA-256 objects in
`state/objects`. Identical content is shared across revisions, snapshots and
incidents; no second snapshot-content directory or vault sidecars are created.

* First valid Markdown capture creates an initial snapshot. Ordinary snapshots
  of changed content are spaced by **at least 300 seconds per document** by
  default. Rapid observed edits retain every revision but coalesce into the
  latest pending snapshot. Reconcile again after the interval, even without a
  new edit, to snapshot that head. No watcher or timer runs yet.
* Before a tombstone or reliable move, pending head content is snapshotted in
  the same metadata transaction. Moves with new content also force a snapshot
  of the resulting head. Orderly shutdown flushes pending heads; startup promotes
  a pending captured head before observing new disk changes. These safety
  exceptions bypass spacing but never duplicate unchanged content. The CLI is
  short-lived, so its shutdown may snapshot an edit within five minutes.
* The persisted policy defaults to **7 days retention**. Every snapshot records
  a fixed expiration deadline using the policy at creation. Policy changes affect
  new snapshots only. Expiration currently means **eligible**, not erased:
  expired snapshots remain listed, inspectable and exportable. There is no
  automatic snapshot pruning, revision deletion or object GC.
* A snapshot preserves document/revision IDs, original observed path spelling,
  full content hash and byte length, snapshot/observation timestamps and reason.
  Listing by any historical path uses the vault's Unicode/case-fold comparison
  and returns all matching identities, including deleted/recreated names.

All commands retain the existing option order. IDs are printed as hex; hyphenated
UUIDs are also accepted. Use `snapshots` without a selector to discover IDs.

```sh
.build/debug/andesite-server snapshots --vault "$sample/vault" --state "$sample/state" note.md
.build/debug/andesite-server snapshots --vault "$sample/vault" --state "$sample/state" DOCUMENT_ID
.build/debug/andesite-server snapshot-inspect --vault "$sample/vault" --state "$sample/state" SNAPSHOT_ID
.build/debug/andesite-server snapshot-compare --vault "$sample/vault" --state "$sample/state" OLD_ID NEW_ID
.build/debug/andesite-server snapshot-export --vault "$sample/vault" --state "$sample/state" SNAPSHOT_ID "$sample/recovered.md"
.build/debug/andesite-server snapshot-storage --vault "$sample/vault" --state "$sample/state"
.build/debug/andesite-server snapshot-config --vault "$sample/vault" --state "$sample/state" 300 604800
```

Inspection prints metadata and exact content. Comparison reports exact-byte line
insertions/removals with zero-based offsets, not an applicable unified patch;
it is bounded to 256 KiB and 2,000 lines per file. Export larger files to compare
with another tool. Export verifies hash/length and atomically publishes a synced,
private, **new file outside vault and state**, never overwriting a target or
following symlinks. Its parent directories must already exist and be safe.
`pendingDocuments` in storage status counts observed heads awaiting snapshots;
byte counts cover registered objects, not SQLite overhead or crash-created orphans.

**In-place restore is intentionally deferred.**
`snapshot-restore --vault ... --state ... SNAPSHOT_ID --in-place` explicitly
fails with `restorationRequiresMutationJournal` and never writes source files.
Export and review a snapshot now; do not treat export as an in-place restore.
Before enabling overwrite, Andesite must journal the operation, preserve the
current file as a preimage snapshot, and recover safely from every mutation phase.

## Recovery contract and limits

This milestone introduces **observation-only recovery**, not the v1 mutation
journal. No runtime operation writes source vault files.

* Object contents and directory are synced before catalog references are
  committed. Per-file revision/head/object metadata/event/sequence publication
  is one SQLite transaction (WAL, foreign keys, FULL synchronous mode).
* A scan is not a global transaction or atomic filesystem snapshot. Earlier
  successful files remain captured if a later file fails. Restart/reconcile
  retries idempotently; unchanged heads are reused. The final namespace is
  checked again, but edits after an observation can only be captured next time.
  Unobserved intermediate editor versions cannot be recovered.
* Index publication is a separate rebuildable transaction. A crash between
  capture and indexing leaves a stale index excluded by the head check; the
  next reconciliation reindexes verified heads. Runtime search cannot bypass
  reconciliation. Direct primitives still require their documented ownership
  and serialization preconditions.
* Startup and reconciliation verify catalog integrity/head references and every
  registered object hash/length. Missing/corrupt objects, newer schema, unknown
  vault identity/root directory replacement and unresolved consistency failures
  stop the operation; there is no silent reconstruction from current notes.
  An earlier manually seeded primitive-only catalog may be refused because it
  lacks this runtime's physical root identity binding. Do not delete its state
  to "repair" it; retain history and arrange an explicit migration.
* Crash-created temporary/unreferenced objects are retained, not garbage
  collected or treated as revisions. They do not prevent retry. Registered
  objects, including retained history/incidents, must verify. No history pruning.
* Deletions publish durable parent-linked tombstones, retaining all content,
  revisions and snapshots. Recreating a deleted filename allocates a new ID.
  A complete second scan must agree with the first scan's names/fingerprints,
  and a later descriptor-relative absence check must succeed before deletion.
  Failed, incomplete, unstable or unsafe scans never authorize disappearance.
* External moves use unique device/inode/**birthtime** evidence, never hashes.
  On macOS this handles moves, swaps, path reuse, Unicode and case-only renames.
  Missing or ambiguous evidence becomes deletion + creation, without merging
  histories. Current Linux `stat` hints lack birthtime, so cross-path moves
  conservatively become deletion + creation. Atomic editor saves at the same
  exact path still retain identity. An unverified spelling-only change can remain
  unreconciled if a case-insensitive filesystem prevents confirming absence.
  A moved invalid UTF-8 file defers namespace
  publication, retains an incident, and quarantines its old identity until fixed.
* The advisory lock coordinates one state directory, not editors or another
  state directory pointed at the same vault. Operators must not configure the
  same vault twice. State directories must remain trusted and not be mutated
  by other processes. Network filesystems and concurrent state manipulation
  are unsupported. Directory fsync is required; power-loss durability has not
  been experimentally qualified. This is not a coherent online backup tool.

Not implemented: watchers, automatic retries, server writes/mutation-journal
recovery, in-place restore, attachment scanning, quotas/GC, authentication,
HTTP API, full-vault sync manifests/cursors/offline synchronization or web client.
Invalid UTF-8 bytes remain incident history, not valid Markdown snapshots; a file
that was never valid has no document snapshot yet. The basic
extractor lacks complete v1 frontmatter/wiki syntax/tags/link resolution,
backlinks, snippets, pagination and index generations.

## Verification and next milestone

The test suite preserves the 14 prior tests and adds focused integration coverage
for spacing/coalescing, shutdown/restart, deletion/recreation, reliable and
ambiguous moves, Unicode/case-only renames, path reuse/swaps, interrupted snapshot
registration, atomic tombstone publication, quarantine, hash corruption,
no-overwrite export/restore refusal, retention eligibility, shared references,
process ownership and SQLite writer contention. All use temporary vaults/state.
No production notes are used. See the file-recovery contract for failure boundaries.

Local macOS arm64 verification: **`swift build` and all 21 `swift test` tests pass**
(14 prior + 7 new integration tests). CLI smoke checks cover every new command,
and an actual SIGKILL between revision commit and snapshot registration verified
WAL recovery before a newer disk version was ingested, without overwriting it.
Existing unused-dependency/test and Homebrew SQLite deployment-version warnings
remain; Linux execution and actual power-loss behavior have not been qualified.

Next: implement and fault-test the mutation journal/preimage preservation before
in-place restore; qualify filesystem race/power-loss behavior and Linux birthtime
support. Watchers and authenticated read-only HTTP can build on the separated
observation, durable capture and snapshot scheduler afterward.
See `docs/andesite-file-recovery.md` for the implemented local contract and storage
migration. `docs/andesite-server-spec.md` and
`docs/andesite-protocol-v1.schema.json` describe the **planned** v1 HTTP/sync
contract, not an implemented listener. Their 24-hour full-vault sync snapshots are
not these 7-day individual-file recovery snapshots.
