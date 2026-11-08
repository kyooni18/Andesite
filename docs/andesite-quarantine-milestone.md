# Quarantine recovery and artifact lifecycle — engineering report

## 1. Recovery workflows

The local CLI/runtime can inspect a quarantine without printing document contents,
export live or immutable competing versions without overwriting a destination,
accept/preserve a verified current document, complete a verifiably published
restoration, or cancel verified unpublished work. All resolution strategies preserve
observed competing bytes in the existing object store before publishing a decision.
They never rewrite a vault document. See the README and
[recovery contract](andesite-file-recovery.md#explicit-quarantine-workflow-schema-v7)
for exact commands, prerequisites and refusal cases.

## 2. Journal and catalog consistency

The original `prepared → staged → published → catalogued → completed` progression
and cancellation/quarantine states remain. Additive schema v7 records stage-creation
identity, pinned pending/completed decisions, prior decision audit history, preserved
version references and pending/retired cleanup receipts. A decision retains its
automatic-refusal diagnostic, base revision, exact observed evidence, strategy and
result revision. Catalog/head/event/FTS/snapshot/outcome publication is transactional.
Completed retries do not duplicate revisions; changed pending evidence fails closed.
Later displaced-inode conflicts can be re-quarantined and explicitly resolved while
retaining all earlier decisions/versions. Pending cleanup blocks ordinary operations.

## 3. Ownership and retirement

Only exact journal-owned artifacts with verified device/inode/birth identity,
safe descriptor-relative parents and expected contents are retirement-eligible.
Unfinished/quarantined references veto retirement. A no-follow bounded census
can follow renamed documents and moved artifact parents conservatively; content
hashes and filenames alone never establish identity.

Cleanup requires explicit `mutation-cleanup --retire`; dry-run is available and
there is no automatic cleanup. It preserves exact bytes and an immutable reference,
commits intent, revalidates identity/content, unlinks one owned basename, syncs its
parent, then commits a receipt. An interrupted unlink is resumed only with durable
intent/object/parent evidence. Retired paths lose their scan exclusions, and later
unrelated occupants never inherit deletion authority. This is not general GC.

## 4. Storage accounting

Diagnostics separate snapshot logical bytes, unique snapshot/object logical bytes,
registered object bytes, deduplicated object allocated blocks, transient object
blocks, known journal artifact blocks, retirement-eligible blocks and retained
blocks. Mutation-version references are included in per-object reference counts.
Uncertain ownership is flagged as incomplete accounting, not reclaimable space.
APFS clones/compression and open descriptors prevent treating allocated-block sums
as guaranteed exclusive reclaimable volume space. Snapshot logical bytes are not
additional physical storage; history and object deletion remain out of scope.

## 5. Verification

`swift build` and `swift test` pass on the development macOS/APFS host: **31 tests**,
retaining all 26 prior test functions with schema-fixture updates. Five focused new
integration tests cover competing versions, all resolution strategies, repeat and
interrupted resolutions, pinned-evidence drift, late re-quarantine, exact exports,
cleanup refusal/receipts, identity mismatch, symlink substitution (including at
the pre-unlink hook), parent/nested/file/case/Unicode relocation, path reuse,
existing-v6 journal migration and allocated storage accounting.

Real subprocess SIGKILL tests cover the original 16 restoration boundaries and
seven new boundaries: resolution intent/written/completed and retirement
intent/before-unlink/unlinked/completed. Assertions check exact document/snapshot
bytes, revision/event lineage and counts, FTS results, SQLite integrity and foreign-key constraints,
journal/receipt state, restart idempotence and survival of unrelated files. A CLI
smoke test also exercised inspection, export, resolution, artifact listing,
dry-run/retirement, storage and search using temporary vault/state directories only.

## 6. Platform and reliability limits

Restoration/maintenance remains qualified only for local macOS/APFS with atomic
Darwin exchange, required file/directory barriers and metadata-copy support.
Linux restoration is not implemented or claimed tested. Existing dependency and
host SQLite deployment warnings remain. SIGKILL validates process-crash recovery,
**not physical power-loss durability**, hardware caches or torn-write behavior.

The state-directory process lock serializes Andesite, not other applications.
Explicit retirement requires stopped editors/outstanding writers and a trusted,
quiescent namespace. There is no kernel content-CAS or atomic unlink-by-verified-
inode guarantee against a same-UID race or a late write through an open descriptor.
Snapshots/exports preserve bytes, not unique displaced ACL/xattr metadata; retain a
filesystem backup when metadata recovery matters. No automatic cleanup is enabled.

## 7. Remaining risks and next milestone

Ambiguous/missing identity, unsafe paths, replaced roots, missing immutable objects,
catalog divergence and changed pinned pending decisions remain fail-closed. There
is intentionally no command to silently supersede a pending decision after a new
edit: export preserved hashes and live versions for manual review. Pre-v7 partial
stages with no durable identity cannot be safely adopted/retired. Census limits
bound maintenance work; root relocation and general catalog repair are not provided.
Disk-full/flush-failure, cross-platform CI and physical power-loss qualification
remain release work.

The recommended next milestone is macOS FSEvents observation through the existing
serialized reconciliation boundary, with full rescans on lost/overflowed events,
followed by Linux inotify. Watchers must not choose quarantine resolutions or
retire evidence automatically. HTTP APIs, authentication, remote synchronization,
general mutation APIs and broad history/object garbage collection remain excluded.
