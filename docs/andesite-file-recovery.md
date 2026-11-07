# Local file recovery — implemented contract

This document describes the snapshot milestone, not the planned HTTP protocol.
The vault is still canonical for visible files. Recovery snapshots are retained,
immutable **whole-file versions**; they do not rewrite source or replace revision
history. All runtime work is synchronous and serialized under the state-directory
process lock. No listener, watcher or background scheduler is started.

## Storage and migration

Catalog version **5** adds only `snapshot_policy` and `recovery_snapshots` and
their indexes/constraints, transactionally. No existing entries, revisions,
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
* Bytes live **only in the existing `state/objects/<sha256>` store**. Existing
  objects are fully verified and reused without writing another temporary copy.
  Hashes are over exact bytes, including BOM, CRLF and Unicode composition.

SQLite WAL and FULL synchronous mode retain metadata across SQLite crash/WAL
recovery. The object file and containing directory must be synced before any
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
release gates; tests currently inject transaction failures and reopen state.

## Retention and usage

`expires_at` is fixed using the creation-time policy. Configuration updates are
persisted and affect future snapshots only. `snapshot-storage` reports expiration
eligibility, pending document count, logical snapshot bytes, unique snapshot bytes,
all registered object bytes, and per-object snapshot/revision/incident reference
counts (including resolved incidents and expired snapshots).

**No expiration pruning or destructive GC runs.** Expired snapshots remain listed
and recoverable. Revision/incident retention is independent and presently
indefinite. Usage excludes catalog/WAL size and unregistered orphan/temporary
files. Future pruning must be explicit, account for every reference/pin, and have
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

In-place restoration is **not implemented**. The explicit `snapshot-restore ...
SNAPSHOT_ID --in-place` command verifies the snapshot then refuses without any
source mutation. Safe restoration requires the mutation journal in server spec
§6, a verified/snapshotted current preimage before overwrite, same-filesystem
staging/atomic replacement, directory durability, post-check, and idempotent
restart recovery/conflict handling. Export is not a shortcut around that gate.

Next milestone: implement that journal and qualify failure/race boundaries for
restoration before adding filesystem watchers or mutation HTTP APIs. Linux
birthtime/statx evidence, incident-history recovery UX, large-vault pagination,
explicit administrator relinking of ambiguous candidates, and independently
audited pruning remain follow-ups.
