# Andesite — integrated local backend (experimental)

A Swift 6 headless Markdown vault backend. **Local CLI ingestion, search,
per-file recovery snapshots, journaled in-place restoration (macOS/APFS),
tombstones, conservative external moves, macOS FSEvents monitoring and
same-user read-only HTTP over Unix sockets and an opt-in authenticated
Hummingbird HTTP server on 127.0.0.1 work end-to-end. Remote/public HTTP
serving and synchronization are not implemented.**
Use temporary test vaults, not production notes; filesystem/power-loss
qualification and full v1 recovery remain outstanding.

## Vault-local path marker (no global registry)

Each Vault stores its own `.andesite/` folder **inside that Vault**.
There is no home-level Vault registry and no Vault-selection table in SQLite:

```text
/absolute/path/to/vault/
  note.md
  .andesite/
    vault.json
    .vault.lock
```

The entire contents of `vault.json` are a single path field:

```json
{"path":"/absolute/path/to/vault"}
```

No note bytes, file metadata, hashes, snapshots, document index, database,
or state-directory location are stored in this marker. Registration does not
scan Markdown, create SQLite state, or start watching.

```sh
.build/debug/andesite-server vault-add /absolute/path/to/vault
.build/debug/andesite-server vault-info /absolute/path/to/vault
.build/debug/andesite-server vault-remove /absolute/path/to/vault
```

Registration creates `<vault>/.andesite/` with mode 0700, and writes
`vault.json` with mode 0600 using an atomic replacement. Registering the
same path again is idempotent. If a Vault moves, registering its new path
updates the marker. There is no global `vault-list` command.
Unregistering removes only the marker, preserving notes and any other
files within `.andesite/`.

The Markdown scanner validates and skips the private top-level
`.andesite/` directory. It also safely skips root `.obsidian/`
(Obsidian settings/plugins), `.trash/` (discarded notes), and
`.git/` (repository metadata), preserving their contents.
Linked or unsafe reserved folders are rejected rather than followed.

**The existing backend state directory remains separate.** Explicit
`watch` / `reconcile` commands still use `--vault` and
`--state`. This change does not relocate the existing SQLite catalog
or snapshot history into the Vault.

## Opening and closing a Vault

Selection and backend operation remain separate. Merely choosing a directory
writes only its path marker and does **not** index notes. A subsequent
explicit open creates/connects a backend outside the Vault, reconciles
the selected folder, and closes cleanly after the command completes:

```sh
.build/debug/andesite-server vault-add /absolute/path/to/vault
.build/debug/andesite-server vault-state /absolute/path/to/vault
.build/debug/andesite-server vault-open /absolute/path/to/vault
.build/debug/andesite-server vault-watch /absolute/path/to/vault # Ctrl-C closes it
```

On macOS, the simplest long-lived background open/close workflow uses an
optional per-Vault LaunchAgent, without manually specifying the state path:

```sh
swift build -c release
python3 scripts/andesite-vault.py select /absolute/path/to/vault
python3 scripts/andesite-vault.py open /absolute/path/to/vault
python3 scripts/andesite-vault.py status /absolute/path/to/vault
python3 scripts/andesite-vault.py close /absolute/path/to/vault
```

Opening starts the existing FSEvents watcher and same-user read-only HTTP.
Closing unloads the LaunchAgent, waits for graceful termination and snapshot
flush, and leaves notes, markers, SQLite state and snapshots intact.

Default backend state is private and **outside the Vault**, under
`~/Library/Application Support/Andesite/States/`. Its key is derived
from macOS directory identity (device, inode, birthtime), not its pathname.
Same-volume renames retain the catalog and revision history; after verifying
that the same directory has moved, the Vault marker records its new path.
Copies to another device or a different inode must not inherit recovery data
implicitly, so a displaced marker without its old identity fails closed.

The existing explicit `--vault`/`--state` commands remain
supported. To reuse an earlier manually configured state without copying
or resetting its DB, use
`vault-open /path/to/vault --state /existing/private/state`.
See the [Vault session lifecycle](docs/andesite-vault-session.md).

## Authenticated local HTTP server (Hummingbird)

Andesite now offers an optional **read-only Hummingbird HTTP/1.1 server**
bound to 127.0.0.1. It authenticates with a 64-hex-character bearer token,
and proxies requests into the already-running Vault watcher without
opening an independent SQLite connection or exposing file mutations.

```sh
# Terminal A: existing Vault monitor
.build/debug/andesite-server vault-watch /absolute/path/to/vault

# Terminal B: HTTP server (macOS 14+)
export ANDESITE_API_TOKEN="$(openssl rand -hex 32)"
.build/debug/andesite-server api-serve /absolute/path/to/vault --port 8788

# Client shell using that same token
curl -H "Authorization: Bearer $ANDESITE_API_TOKEN"   http://127.0.0.1:8788/v1/status
```

The server requires the existing watcher to be healthy and exposes
read-only status, phrase search, paginated Markdown documents, immutable
head content, outgoing links, resolved incoming backlinks, and recovery
snapshots. Search hits include Vault-relative paths. Document detail
contains CommonMark headings and lexical links; linked backlinks are
resolved against the current indexed note IDs. A coalescing work
scheduler runs file reconciliation before disposable cached link-graph
updates; GET requests page in-memory data without reparsing notes.
Obsidian unlinked mentions, full Properties, rename rewrites and
large-Vault parity remain unimplemented.

From a separate local client, the same-user Unix socket supports:

```sh
python3 scripts/andesite-api.py --state /absolute/private/state documents
python3 scripts/andesite-api.py --state /absolute/private/state document DOCUMENT_ID
python3 scripts/andesite-api.py --state /absolute/private/state document-content DOCUMENT_ID
python3 scripts/andesite-api.py --state /absolute/private/state links DOCUMENT_ID
python3 scripts/andesite-api.py --state /absolute/private/state backlinks DOCUMENT_ID
```

No LAN listener, CORS, TLS, remote auth, write API, restoration or sync
is provided yet. See [the Hummingbird API contract](docs/andesite-http-server.md)
and the end-to-end `scripts/test-api-server.sh` test.
Track what still differs from Obsidian in the
[compatibility register](docs/obsidian-compatibility.md).
The [work scheduler design](docs/andesite-work-queue.md) explains
immediate filesystem edits, deferred indexing, priority and cache
invalidation without a second SQLite owner.


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
No arguments/unknown commands fail closed; only the opt-in
`api-serve` opens an authenticated loopback TCP listener.

## Continuous monitoring (macOS)

The `watch` command opens a real FSEvents stream **before** the startup full
reconciliation, then runs on a single synchronous owner thread until SIGINT or
SIGTERM. It owns the state lock for its entire lifetime:

```sh
.build/debug/andesite-server watch --vault "$sample/vault" --state "$sample/state"
```

File events (including loss/overflow hints) cause a **full secure rescan** through
the existing `VaultRuntime.reconcile()`; FSEvents paths are not trusted as file
identities. Events are coalesced for 400 ms (maximum 2 seconds), and a full
fallback scan occurs every five minutes, including after relaunch. A separate
15-second timer promotes already captured revisions to recovery snapshots once
the per-document minimum snapshot interval has elapsed. A clean stop flushes
pending captured content. No callback reads files or mutates the catalog.

For opt-in background execution via a per-vault macOS LaunchAgent, see
[watcher operations](docs/andesite-watcher.md). An agent is **not automatically
installed**: explicitly choose a test vault and private state directory.

The watcher serves **read-only HTTP/1.1 over a private Unix socket**, with no
TCP port and no second database connection. While watching, query it using:

```sh
python3 scripts/andesite-api.py --state "$sample/state" status
python3 scripts/andesite-api.py --state "$sample/state" search 'initial phrase'
python3 scripts/andesite-api.py --state "$sample/state" snapshots --path note.md
```

See [read-only local API](docs/andesite-local-http.md) for endpoints and
authorization. A separate `andesite-server` CLI still cannot open the same
state while watching; use the bundled client for reads or stop watch for
maintenance/write operations.

FSEvents is advisory; intermediate edits between scans are not guaranteed
versions, and physical power-loss behavior is not qualified. Source Markdown
is never modified by the watcher. There is no **TCP** listener or sync service.

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
  invalid UTF-8, controls, traversal, backslashes and reserved `.andesite*`
  names are rejected. The verified, private top-level `.andesite/` is
  the sole exception: it is skipped without indexing its contents. This is not yet a version-pinned cross-platform Unicode table.
* Ordinary observation never rewrites canonical files. Two bounded byte/metadata reads
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
incidents; no second snapshot-content directory is created. Journaled restoration
retains a hidden displaced-inode artifact in the destination directory (see below).

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
.build/debug/andesite-server snapshot-restore --vault "$sample/vault" --state "$sample/state" SNAPSHOT_ID --in-place
.build/debug/andesite-server mutation-journal --vault "$sample/vault" --state "$sample/state"
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

### Journaled in-place restoration

`snapshot-restore --vault ... --state ... SNAPSHOT_ID --in-place` restores an
**existing live Markdown document** at its current path, even if the snapshot
was captured before a rename. Deleted documents are export-only. It refuses a
changed target: first reconcile and review external edits before retrying.

The current complete bytes are verified and committed as a **preimage snapshot**
before any source mutation. Existing identical revision snapshots are reused;
otherwise preimages bypass snapshot spacing/hash coalescing. Restoring even
identical content creates a **new child revision**, never rewinds history.
Restored bytes, revision, event, snapshot and FTS publication are consistent.
Output identifies the document, supplier snapshot, preimage, new revision,
operation and completion state. `status` includes `unfinishedMutations`.

A persistent schema-v6 journal separates SQLite commits from filesystem
publication: `prepared → staged → published → catalogued → completed`. On
restart, unpublished work is cancelled; verified, already-published work finishes
idempotently. Ambiguity is **quarantined**, blocking reconciliation/search/new
restores while snapshot inspection/export and `mutation-journal` remain available.
There is no automatic destructive rollback. Schema v7 adds explicit, non-destructive
quarantine decisions, preserved competing versions and verified artifact retirement.

Restoration uses no-follow descriptor-relative traversal, exclusive same-directory
staging, metadata copying, atomic **exchange**, file durability barriers and
parent-directory synchronization. The displaced inode remains at
`.andesite-mutation-OPERATION_ID` until explicitly retired: do not remove or edit
these artifacts manually. Only exact journal-owned paths/inodes are ignored by
ordinary scans. `snapshot-storage` includes their allocated-block estimates.
Owned inodes and their parent directories can be located after renames/nested
moves without adopting unrelated files at reused paths. Ambiguous identity stays
quarantined; matching names, timestamps or content alone never establish identity.

### Resolve a quarantine and retire redundant artifacts

Stop editors (including processes holding the old inode open), and back up vault
and state together before maintenance. Inspection never prints document contents:

```sh
.build/debug/andesite-server mutation-journal --vault "$sample/vault" --state "$sample/state"
.build/debug/andesite-server mutation-inspect --vault "$sample/vault" --state "$sample/state" OPERATION_ID
.build/debug/andesite-server mutation-export --vault "$sample/vault" --state "$sample/state" OPERATION_ID artifact /absolute/new-export
.build/debug/andesite-server mutation-resolve --vault "$sample/vault" --state "$sample/state" OPERATION_ID --strategy preserve-current
.build/debug/andesite-server mutation-artifacts --vault "$sample/vault" --state "$sample/state"
.build/debug/andesite-server mutation-cleanup --vault "$sample/vault" --state "$sample/state" --dry-run
.build/debug/andesite-server mutation-cleanup --vault "$sample/vault" --state "$sample/state" --retire
```

Only choose a strategy offered by inspection:

* `accept-current` / `preserve-current`: accept the verified document inode's
  current valid Markdown, preserving **all observed competing bytes** in immutable
  storage first. Both intentionally have the same non-destructive preservation
  policy; neither rewrites the file.
* `complete-published`: finish a verifiably published intended restoration; reuse
  its allocated restore revision if not already catalogued.
* `cancel-unpublished`: keep the original unchanged document, preserve staging
  bytes, and cancel without a new content revision.

`mutation-export` supports `intended`, `preimage`, `current`, `artifact`,
`path-occupant`, `retirement`, and `sha256:HASH` for any preserved version listed
by inspection. Export is outside vault/state, no-follow and no-overwrite.
Resolution publishes catalog/head/index/snapshot/outcome atomically. A repeated
completed selection is a no-op; a crashed pending decision pins exact evidence
and refuses changed evidence rather than silently changing the selection.

Cleanup is **never automatic**. Only terminal operations with verified owned
artifacts and expected content are eligible. Exact bytes are durably preserved
before a cleanup intent commits; identity/content are rechecked before unlink,
parent sync precedes a durable receipt. Repeat `--retire` after an interrupted
cleanup; pending cleanup blocks reconciliation/restoration. Unfinished,
quarantined, missing-without-intent or uncertain artifacts are retained/refused.
This is not filesystem or object-store GC. Allocated APFS blocks are estimates,
not a promise of exclusive reclaimable volume space (clones/compression/open FDs).
Snapshots/exports preserve file bytes, not a general metadata/ACL backup.

**Platform/concurrency limits:** in-place restoration is currently enabled only
when vault and state use local **macOS/APFS**. Linux and other filesystems fail closed; export remains
available. Atomic exchange is **not a content compare-and-swap**: stat/hash checks
cannot exclude an external edit in the final syscall window or writes through an
already-open descriptor. Detected changes retain evidence and quarantine; the
original/displaced inode is never automatically deleted. A completed operation
means verified at completion, not immunity to later edits. Keep backups.
Filesystem namespace ownership and private state must remain trusted. See the
[technical contract](docs/andesite-file-recovery.md#mutation-journal-and-restoration)
for recovery states, handling conflicts and remaining limits.

## Recovery contract and limits

Ordinary reconciliation remains read-only. Only explicit journaled restoration and artifact retirement
mutate the vault; it is a local subset, not the full v1 mutation service.

* Object contents and directory are synced before catalog references are
  committed. Per-file revision/head/object metadata/event/sequence publication
  is one SQLite transaction (WAL, foreign keys, FULL synchronous mode).
* A scan is not a global transaction or atomic filesystem snapshot. Earlier
  successful files remain captured if a later file fails. Restart/reconcile
  retries idempotently; unchanged heads are reused. The final namespace is
  checked again, but edits after an observation can only be captured next time.
  Unobserved intermediate editor versions cannot be recovered.
* For external observations, index publication is a separate rebuildable transaction. A crash between
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
  been experimentally qualified. Actual SIGKILL/restart recovery is tested, not
  physical power loss. This is not a coherent online backup tool.

Not implemented: Linux inotify monitoring, automatic mutation retries, Linux in-place restoration,
general-purpose server mutations,
attachment scanning, quotas/GC, remote HTTP authentication and write API,
full-vault sync manifests/cursors/offline synchronization or web client.
The macOS-only Unix-socket API authorizes same-UID peers; it does not implement
the planned multi-user, remotely authenticated v1 API.
Invalid UTF-8 bytes remain incident history, not valid Markdown snapshots; a file
that was never valid has no document snapshot yet. The basic
extractor lacks complete v1 frontmatter/wiki syntax/tags/link resolution,
unlinked mentions, snippets, advanced search pagination and index generations.

The [milestone engineering report](docs/andesite-quarantine-milestone.md) records
implementation decisions, verified boundaries and remaining risks.

## Verification and next milestone

`swift build` and `swift test` pass on the macOS/APFS development host with
**67 tests** (61 prior plus three scheduler, two cache and one real
FSEvents cache test). They exercise FSEvents, snapshot promotion, durable mutation recovery,
same-UID HTTP access, live document heads, pagination, immutable
content, syntax-only Obsidian links, and safe preservation of
the .obsidian, .trash and .git folders.
Prior journal/recovery SIGKILL tests remain in the suite. Additional watcher
smoke tests use only temporary vaults and preserve source bytes.

Next: cooperative time-sliced cache refresh for large Vaults,
Obsidian-complete heading/block anchors, unlinked mentions and typed
Properties/frontmatter. Safe journal-backed edits, Bases/Canvas, cross-volume
migration and Linux inotify remain separate priorities.
Network HTTP mutations, remote sync, physical power-loss qualification
and object garbage collection remain separate milestones.
