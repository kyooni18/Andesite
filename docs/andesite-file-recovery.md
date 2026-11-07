# Local file recovery — implemented contract

This document describes the local snapshot and restoration milestones, not the
planned HTTP protocol.
The vault is still canonical for visible files. Recovery snapshots are retained,
immutable **whole-file versions**. Observation is read-only; explicit journaled
restoration appends revision history and replaces a live file. All runtime work is synchronous and serialized under the state-directory
process lock. No listener, watcher or background scheduler is started.

## Storage and migration

Catalog version **5** added `snapshot_policy` and `recovery_snapshots`; version
**6** adds `mutation_journal` and its state index, transactionally. No existing entries, revisions,
incidents, events or immutable objects are removed or rewritten. An older
supported catalog upgrades in place; a newer schema is refused. Keep a coherent
backup of state before upgrading (with Andesite stopped); this is not a backup
or catalog reconstruction tool.

* `snapshot_policy`: one persisted policy per vault, minimum interval and
  retention seconds. Defaults are 300 and 604800 respectively. The API/CLI accepts
  finite intervals >= 0 and retention >= 1 second (both bounded to 100 years).
* `recovery_snapshots`: random ID, vault/document/revision IDs, original path,
  hash and length, monotonically increasing per-document ordinal, Unix timestamp
  and fixed expiration timestamp, reason (`interval`, `rename`, `deletion`,
  `shutdown`, `recovery`). The referenced revision supplies observation time.
  Foreign keys bind the snapshot to an entry, revision and registered object;
  runtime integrity checks additionally require matching entry/hash/length/path
  and a non-tombstone revision. Each revision can be registered only once per
  document. Ordinals, not wall-clock timestamps, order snapshots.
* Immutable snapshot bytes live **in the existing `state/objects/<sha256>` store**. Existing
  objects are fully verified and reused without writing another temporary copy.
  Hashes are over exact bytes, including BOM, CRLF and Unicode composition.

SQLite WAL and FULL synchronous mode (plus `fullfsync` and `checkpoint_fullfsync`
on Darwin) retain metadata across SQLite crash/WAL recovery. The object file and containing directory must be synced before any
reference commits. Snapshots do not depend on ancestors' bytes for reconstruction.
Losing/corrupting the operational catalog cannot be repaired faithfully from
current notes or guessed object names. Startup fails closed rather than resetting
state or reconstructing history. Back up the **catalog and objects together**.

## Capture versus scheduling

`VaultReader` performs bounded, no-follow stable observations. `ExternalCapture`
first makes bytes durable, then publishes revision/head/object/event metadata in
a SQLite transaction. `RecoverySnapshots` makes a separate scheduling decision
from these already captured revisions; it does not read mutable files. This is
the boundary future watcher-driven observations will use too.

1. Initial valid capture receives a snapshot immediately.
2. A changed head receives an ordinary snapshot only when the previous snapshot
   is at least the configured interval old. Unchanged content never does. The
   check runs even if the current reconciliation creates no new revision.
3. Rapid edits retain each **observed** revision but coalesce the pending recovery
   snapshot to the latest head. Returning to the last snapshot's bytes cancels
   pending work. Returning to older bytes after a different snapshot is a genuine
   new version and may get another snapshot referencing the same object.
4. Pending heads are flushed before tombstones/moves, on explicit orderly
   `shutdown()`, and at startup **before new observations**. These are safety
   exceptions to spacing. A changed resulting move head is also snapshotted.
   Pure path changes do not duplicate unchanged snapshot content; historical
   paths are still retained in move revisions.
5. There is no volatile scheduling queue: a head differing from the last snapshot
   is durable pending work. Startup flushes interrupted registration even if a
   newer version is already on disk. It uses verified old objects, not current
   vault bytes. `deinit` only closes resources; callers must handle throwing
   `shutdown()` for orderly flush/error reporting. The CLI does so on success
   and on command failure. Neither shutdown nor startup does a final source scan.

The interval is minimum spacing for **ordinary**, not emergency snapshots. A
short-lived CLI invocation can thus snapshot an edit inside five minutes at
shutdown. A clock moving backwards delays ordinary snapshots; it never deletes
history, and force-flush exceptions remain available. Unobserved or overwritten
editor versions cannot be recovered. Invalid UTF-8 stays durable incident
history, not a valid Markdown snapshot. A never-valid file has no snapshot entry.

## Namespace reconciliation

An initial complete no-follow scan includes names and fingerprints. Stable file
observations must agree with that scan. Unchanged-path observations may publish
independently, so later failure does not discard earlier captured versions.

Cross-path association uses a **unique** retained device/inode/birthtime identity
and a unique scanned match. An inode alone, content hash or name similarity is
never enough. This handles path reuse and swaps without merging unrelated IDs.
An atomic-save replacement at an otherwise unchanged exact path retains that
path's ID. A copy to a different path is not a move. Ambiguous/missing evidence
becomes a new identity plus a tombstone for confirmed disappeared files.

macOS supplies birthtime in the current stat implementation; Linux currently
does not, so unpaired Linux moves fall back conservatively. Legacy hints without
birthtime are valid but cannot relink paths until refreshed. Filesystem-reported
name spelling is preserved byte-for-byte; portable namespace keys use NFC and
case folding, and history lookup uses those same keys. No normalization is
written back to disk. A spelling-only change lacking identity evidence may remain
unreconciled on a case-insensitive filesystem if absence cannot be confirmed.

Only after **all** observations succeed and a second complete scan agrees with
the first names/fingerprints can absence checks authorize tombstones. A subsequent
descriptor-relative absence check accepts only ENOENT, never permission/I/O,
symlink, mount or type errors. A recreation after that check is a later creation
when observed; enumeration is not a global atomic filesystem snapshot.

One namespace transaction:

* Force-snapshots any pending old head before deletion or move.
* Publishes parent-linked tombstones, retaining the old path in the revision and
  clearing the entry's live path/key. Tombstone IDs are never reused.
* Temporarily releases all verified move names, then publishes moved heads and
  deferred new entries together. Swaps/path reuse do not expose reserved entries
  or partial identity updates outside the transaction.
* Snapshots changed resulting move heads, registers events and allocates sequences.

A moved invalid file is captured as an incident and namespace publication is
deferred until it can be observed validly; it cannot turn a failed/quarantined
move into a tombstone. Quarantine follows the affected identity as well as
unassociated incident paths. Disappearing incidents remain retained, not silently
treated as corrections. Deleted documents remain selectable by ID or any recorded
path, and recreation at an old filename creates a separate history.

The FTS transaction is separate and rebuildable. A later index failure cannot
expose stale heads or invalidate already completed absence evidence. Search
reconciles first and fails if the operation fails.

## Interruption boundaries

| Interruption | Retained state and retry |
|---|---|
| Before object durability | No metadata reference; source is untouched. |
| After object publish, before metadata | Orphan object/temp may remain; retained, not adopted as history or deleted. Retry verifies/reuses the object. |
| During revision/head/event publication | SQLite rolls back all its metadata, no partial sequence/head. |
| After revision commit, before snapshot registration | Durable head is pending; startup promotes it before observing newer bytes. |
| During snapshot registration | No partial snapshot identity; unique revision constraint and hash check make retry idempotent. |
| During old-head snapshot/tombstone/move publication | The entire namespace transaction rolls back together, including its snapshots. |
| After namespace commit, before index | Tombstones/moves/snapshots survive; search excludes stale revision indexes and reconciliation reindexes. |

Missing/corrupt registered objects or inconsistent operational references stop
startup/reconciliation/recovery inspection. The implementation never repairs
them from current notes. State must remain private and exclusively owned; the
advisory lock does not block editors or another state directory for the same vault.
Actual power-loss durability and cross-platform race qualification are still
release gates. Tests inject transaction failures and kill real CLI subprocesses
at restore boundaries; see the mutation-specific matrix below.

## Retention and usage

`expires_at` is fixed using the creation-time policy. Configuration updates are
persisted and affect future snapshots only. `snapshot-storage` reports expiration
eligibility, pending document count, logical snapshot bytes, unique snapshot bytes,
all registered object bytes, and per-object snapshot/revision/incident reference
counts (including resolved incidents and expired snapshots).

**No expiration pruning or destructive GC runs.** Expired snapshots remain listed
and recoverable. Revision/incident retention is independent and presently
indefinite. Usage excludes catalog/WAL size and unregistered orphan/temporary
files, including retained mutation artifacts. Future pruning must be explicit, account for every reference/pin, and have
crash-tested mark-and-sweep before unlinking any object. Expiration eligibility is
not permission to remove an object shared with any revision, snapshot or incident.

## Inspection and recovery

README documents every CLI command, all with `--vault` and `--state`. Listing
requires no scan, includes expired/deleted history, and can return multiple IDs
for a historical filename. Inspection verifies hash/length before returning
contents. Comparing is byte-sensitive, line-based and bounded (256 KiB / 2000
lines per input); it is for review, not a patch engine. Larger files can be
exported and compared externally. Listing is currently unpaginated.

Export is available now: secure descriptor-relative parent traversal, no source
writes, private exclusive temporary file, full file sync, atomic no-replace
publication, directory sync. Existing files/symlinks are never overwritten, and
vault/state directory identities are excluded even through case aliases. Parent
directories must already exist, reject writable non-sticky ancestors, and the
destination parent must belong to the OS user. If final directory sync fails,
the command reports failure and may leave the complete exported file; it never
claims success or removes a pre-existing target. Crash-created export temporary
files can remain outside state; they are not automatically collected.

## Mutation journal and restoration

### Scope and intent format

Only `snapshot-restore ... SNAPSHOT_ID --in-place` writes canonical Markdown.
`VaultRuntime` remains the serialized coordinator and owns the process lock,
SQLite, object store and reader. Startup validates catalog/objects and recovers
journal operations **before** pending-head snapshot promotion or any ordinary
reconciliation. A busy database fails startup/restore, not a filesystem rollback.
Unknown/corrupt objects or root/catalog identities stop startup without resetting
state. Quarantined journal rows permit historical inspection/export and diagnostics,
but block normal reconciliation, search and new restores globally for that vault.

`mutation_journal` is a WITHOUT ROWID SQLite table keyed by `(vault_id,id)`:

* Stable document ID and supplier snapshot ID; mandatory preimage snapshot ID.
  Hashes, lengths and full immutable bytes are referenced through these snapshot
  records, not copied into a mutable journal blob. Snapshot/document/lineage
  relationships are verified before redo.
* Parent revision and a preallocated new revision ID. Redo never allocates a
  second restore revision. A restore's `origin` is `restore`; it gets a normal
  ordered `updated` change event. This local journal is separate from the future
  HTTP client `operations` deduplication table.
* Current target path, random exact artifact basename, original fingerprint,
  staged fingerprint once durable, and device/inode identities of the complete
  parent chain. Fingerprints include size, nanosecond mtime/ctime and Darwin
  birthtime; the vault root must also match its persisted physical identity.
* Explicit state, creation timestamp and content-free diagnostic. Rows are never
  automatically pruned. Artifact names are `.andesite-mutation-<hex operation id>`.

The preimage is made durable **before intent** and is not rolled back if later
journal/staging/publication fails. It references the exact current revision;
spacing and unchanged-hash suppression are bypassed for a revision not already
snapshotted. An already registered revision reuses its snapshot identity. The
preimage and restored snapshots use reason `recovery`; their precise roles are
identified by the journal references. Normal interval/retention policy is unchanged.

### Successful restore

1. Verify snapshot hash/length and live Markdown document identity. Use its
   **current** path, not the snapshot's historical path. Refuse tombstones,
   incidents/current bytes that differ from the captured head, or changed file
   metadata/identity. Reconcile and review external edits before retrying.
2. Capture/verify complete current bytes in the immutable object store, commit
   the preimage snapshot, then commit the `prepared` intent. No source mutation
   occurs before the latter commit. The object directory is synced and a file
   barrier follows directory sync, including for reused objects.
3. Traverse via no-follow directory descriptors; reject unsafe ownership/modes,
   mounts, symlinks, hard links, special/set-ID files and changed parent identities.
   Create the artifact exclusively in the destination directory. Write full
   replacement bytes, copy metadata with Darwin `fcopyfile(COPYFILE_METADATA)`
   (permissions, ownership, ACLs, extended attributes/stat metadata), full-sync the
   file, sync the parent and full-sync again. Commit its identity as `staged`.
4. Acquire a SQLite writer reservation, revalidate original bytes/fingerprint,
   stage identity and parent chain, then `renameatx_np(..., RENAME_SWAP)` exchanges
   stage and target atomically. The previous inode is now the artifact; nothing
   is unlinked. Sync the directory and full-sync the new target. Verify both
   inode identities and both contents plus the parent chain; commit `published`.
   **The writer transaction is not atomic with the exchange.** A crash with a
   rolled-back state is resolved by observing the two inode locations.
5. In one SQLite transaction publish the fixed-ID new child revision, head and
   filesystem hint, event/sequence, restored snapshot and FTS/metadata, and set
   `catalogued`. Even identical content creates a new revision. No old revision
   or snapshot is modified. An index failure rolls back all of this transaction.
6. Reverify visible target and displaced preimage, sync publication, then commit
   `completed`. A missing/new external edit causes quarantine, never rollback.
   Completion describes verified publication at that time, not a lock on editors.

### Minimal recovery state machine

| Durable state / observed files | Startup action |
| --- | --- |
| No intent (including interrupted preimage/intent transaction) | No source modification was authorized. Any committed preimage survives; normal captured-head recovery may register the head. |
| `prepared`, artifact absent | Mark `cancelled`; never retry a source write automatically. |
| `prepared`, artifact present | `quarantined`: partial or unregistered stage has no durable identity. Preserve it; do not adopt or delete it. |
| `staged`, original still at target with exact fingerprint, stage still at artifact with exact identity/bytes | Mark `cancelled`, retain staging artifact. No restart publishes an unpublished restore. |
| `staged` or `published`, stage inode/content at target and original inode/content at artifact, parents unchanged | Exchange already happened. Re-sync filesystem, publish the fixed revision/catalog transaction and complete. |
| `catalogued`, both files still verified | Finish sync/verification and mark `completed`; never reallocate history. |
| `completed` | Never touch visible target. Verify retained displaced inode/bytes for late writes; normal external edits to the visible target are left to reconciliation. |
| `cancelled` | No automatic mutation. Any registered stage remains excluded by exact artifact identity in ordinary scanning. |
| Any ambiguity or mismatch | Mark `quarantined`, preserve filesystem/object evidence. No destructive rollback, overwrite or artifact cleanup. |
| `quarantined` | Remain quarantined on repeated opens. Explicit administrator-reviewed resolution is not implemented. |

A catalog lock/I/O/trigger error does not get mislabeled a filesystem conflict;
it leaves the durable last phase available for another recovery attempt. Once
catalog publication commits, repeating completion/opens never creates another
revision/snapshot/event. **A new explicit restore request is a new operation**
with a new child revision; this CLI does not have client-provided idempotency keys.

### Concurrency, artifact lifetime and limitations

Atomic exchange is not content CAS. External writers need no Andesite lock.
Prechecks detect changes before the exchange; postchecks detect unexpected
replacement/displaced bytes and quarantine rather than silently accepting a
winner. Exchange retains the displaced inode, even if an unexpected regular
file was raced into the target. No symlink target is ever followed. The journal
never automatically rolls back or deletes a preimage/artifact.

An editor holding a file descriptor to the displaced inode can write after
exchange or completion. The artifact is therefore retained **indefinitely**, not
unlinked after a hash check. Startup/reconciliation checks completed artifacts
for such changes and quarantines them for manual review. Recovery cannot capture
an intermediate writer version that disappears before observation, prevent
another editor from overwriting its own file, or guarantee that the visible path
never briefly holds the restored bytes during a last-instruction race. Parent
reopening detects namespace replacement but is not a kernel namespace lock.
The OS user/vault namespace and private state must remain trusted; protection
against a malicious process with the same UID is not claimed. Never configure
the same vault under a second state directory.

Only exact journal artifact path + matching device/inode/birthtime exceptions
are passed to both read-only reconciliation scans; unknown `.andesite*` names
still fail. Retained artifacts are not snapshot storage (immutable snapshots
remain outside the vault). They add destination-disk usage, currently excluded
from `snapshot-storage`. Do not rename/edit/delete them. Moving a restored file
is supported; moving a directory containing an artifact currently quarantines
its old journal namespace rather than guessing a relocation. Artifact retirement,
relocation and administrator quarantine resolution remain unimplemented. For a
quarantine: stop editors, preserve the vault **and** complete state, inspect
`mutation-journal`, export supplier and preimage snapshots to new files, and
review retained artifact/current bytes offline. Do not edit SQLite or remove
artifacts as an automatic "fix"; there is no supported unquarantine command yet.

In-place restore requires **local macOS APFS for vault, state and objects**, with required directory
`fsync`, file `F_FULLFSYNC`, metadata-copy and atomic-exchange support. Failures
are reported and left recoverable/quarantined; unsupported systems never take a
plain-rename shortcut. Linux observation/export still work but restoration fails
before intent until Linux ACL/xattr/label preservation and durability semantics
are qualified. Nonlocal/non-APFS filesystems are refused. No Linux execution was
performed for this milestone. APFS flush ordering depends on the OS/filesystem
and hardware honoring barriers; SIGKILL does **not** establish physical power-loss
safety, controller-cache correctness or torn-write behavior. No destructive
power-loss experiments were run. Coherent backups and independent power-loss
qualification remain release gates.

### Diagnostics and demonstrated tests

* `snapshot-restore ... ID --in-place`: prints document/path, supplier/preimage
  IDs, new revision, operation and completion state. A failure is actionable and
  content-free; inspect the journal before deciding what to recover.
* `mutation-journal --vault ... --state ...`: lists all durable operations,
  states, artifact basenames, IDs and diagnostics plus unfinished count. Opening
  this command first runs normal safe startup recovery. `status` also reports
  `unfinishedMutations`. Cancelled work has no remaining source effect; quarantine
  is counted unfinished even though automatic recovery intentionally stops.
* Snapshot list/inspect/compare/export/storage/config retain their existing syntax.

The macOS/APFS suite has **26 tests**, retaining the original 21 and adding five
focused test functions. The process-death matrix executes real CLI subprocesses
with `ANDESITE_TEST_FAULTS=1` and `ANDESITE_TEST_KILL_POINT=<point>` at 16 points:
`before-preimage`, `preimage-written`, `preimage-preserved`, `intent-written`,
`intent-committed`, `stage-created`, `stage-written`, `staged`, `before-exchange`,
`exchanged`, `published`, `before-catalog`, `catalog-written`, `catalogued`,
`before-completion`, `completed`. Neither variable is set for ordinary use;
there is no fault control in vault contents or the protocol. In-process test
hooks also inject race edits and SQLite locks. Additional subprocess tests kill
during startup catalog redo, introduce newer target edits after exchange, and
write through a real open descriptor to the displaced inode.

Assertions cover exact bytes, mandatory preimages, parent lineage, repeated and
identical restores, nested/Unicode renamed targets, search, mode/xattr metadata,
symlinks/directory replacement, external edits, locks before intent/publication,
corrupt and missing objects, trigger-induced atomic catalog rollback, repeated
restart convergence, history/event/snapshot counts, `PRAGMA integrity_check` and
`foreign_key_check`. These demonstrate process-crash recovery on this host, not
all platform filesystems or physical power failure. Disk-full/flush-failure and
hardware fault qualification remain follow-up work, not proven guarantees.

Recommended next milestone: non-destructive quarantine resolution and artifact
lifecycle/relocation, Linux metadata/durability qualification, and cross-platform
fault CI before continuous monitoring or HTTP mutation APIs. No watchers, HTTP,
authentication, synchronization, automatic pruning or GC were added here.
