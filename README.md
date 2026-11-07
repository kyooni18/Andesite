# Andesite — integrated local backend (experimental)

A Swift 6 headless Markdown vault backend. **Local CLI ingestion and search now
work end-to-end. HTTP serving, authentication and sync are not implemented.**
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
owner; call from one blocking executor, never an NIO event loop. `shutdown()`
closes resources before releasing ownership; startup errors release resources.
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
  stable path-based entry IDs, parent-linked revisions and ordered changes.
  Unchanged bytes do not allocate revisions or change sequences.
* Invalid UTF-8 is stored separately without replacing a good head/history;
  repeated identical open incidents are deduplicated. Corrected valid content
  resolves incidents, even if it matches the previous head.
* Verified immutable revision bytes feed the existing basic swift-markdown
  extractor and FTS. Search is vault-scoped, literal-phrase, bounded, current-head
  checked, and excludes open incidents. It currently indexes raw Markdown with
  a heading title, not complete v1 extracted document text.

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
* Missing previously cataloged paths are explicitly rejected as unsupported
  removal/rename reconciliation **before** ingesting new paths. No deletion is
  ever inferred, including after incomplete scans. Restore the old path or wait
  for an audited deletion/rename implementation; hashes alone do not relink IDs.
* The advisory lock coordinates one state directory, not editors or another
  state directory pointed at the same vault. Operators must not configure the
  same vault twice. State directories must remain trusted and not be mutated
  by other processes. Network filesystems and concurrent state manipulation
  are unsupported. Directory fsync is required; power-loss durability has not
  been experimentally qualified. This is not a coherent online backup tool.

Not implemented: watchers, automatic retries, server writes/journal recovery,
rename/deletion publication, attachment scanning, quotas/GC, authentication,
HTTP API, snapshots/cursors/offline synchronization or web client. The basic
extractor lacks complete v1 frontmatter/wiki syntax/tags/link resolution,
backlinks, snippets, pagination and index generations.

## Verification and next milestone

The suite contains the 10 original tests plus 4 integrated tests covering fresh
scan/search, discovery, edits/history, unchanged ingestion, Unicode, restart,
locking, transaction failure/retry, invalid UTF-8 quarantine, missing/corrupt
objects, unsafe namespaces and unsupported renames. A dedicated recovery test
forces failure between revision capture and index publication, then verifies
stale-result exclusion, partial-scan retry without duplicate revisions/events,
incomplete-scan non-deletion, and newer-schema refusal. Quarantine is also
checked after restart. All use temporary vaults.
`swift build` and `swift test` pass locally on macOS arm64 (14 tests).
Existing unused-dependency/test warnings and the Homebrew SQLite deployment
version linker warning remain. Linux and power-loss behavior were not verified
for this milestone.

Next: audited observation-side deletion/rename handling and persistent scan
health diagnostics, with cross-platform race/fault-injection tests, before
adding authenticated read-only HTTP access. Full server writes require the
specified mutation journal/recovery protocol, not just this ingestion runtime.
See `docs/andesite-server-spec.md` and `docs/andesite-protocol-v1.schema.json`
for the **planned** v1 contract, not a declaration of implemented functionality.
