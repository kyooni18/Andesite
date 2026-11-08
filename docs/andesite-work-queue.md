# Immediate file operations, background jobs and disposable caches

Andesite's macOS watcher has three **logical** layers, backed by a
coalescing scheduler. There is still only one SQLite owner.

## Layer 1: immediate filesystem operations

Editors and other local applications save, create, rename and delete
Vault files directly through the OS. Andesite's FSEvents callback only
records event generations and loss flags. It never indexes Markdown,
opens SQLite, or holds an editor file descriptor.

File edits never wait for parsing or cache construction. The authenticated loopback API now supports version-conditioned
edits of **existing** Markdown documents using the durable journal.
File creation/deletion and rename still require distinct crash-recovery
contracts and are not exposed over HTTP.

## Layer 2: bounded background work queue

`VaultWorkScheduler` is a state machine called on the single-owner
`VaultMonitor` thread. Priority is:

1. Reconcile coalesced FSEvents, namespace and durable SQLite/FTS changes.
2. Register due recovery snapshots.
3. Build or refresh the disposable, derived link cache.

Frontmatter, property and tag projections are committed as part of the
durable per-revision FTS indexing step (1), rather than lazily parsing
each HTTP GET. On a v8-v9 upgrade, missing metadata is backfilled from
immutable current head objects during the first successful reconciliation.
Only the link graph remains a disposable memory cache.

A burst of thousands of events produces one pending scan and at most one
pending cache refresh. Existing 400 ms debounce, 2-second hard coalescing,
300-second fallback scan, and bounded scan/cache retries remain in place.
Failed scans do not authorize stale index views. A known oversized cache
error remains visible until the next scan rather than being silently
reported as an empty set of backlinks.

After a work item, the watcher drains FSEvents again before answering
one private HTTP request. New changes observed during a job make
indexed reads unavailable until reconciliation is complete. On startup,
FSEvents starts before the initial full scan; a successful scan schedules
low-priority cache hydration. After a crash, the full startup scan
recreates pending work, so no second durable job log is required.

**Concurrency boundary:** all jobs still execute on the existing single
SQLite owner thread. Cache work is now cooperative: at most eight heads
or 256 KiB of new Markdown parsing per watcher iteration, followed
by at most eight source documents for link resolution per iteration.
Changes arriving during an unfinished build discard the pending graph.
A large full reconciliation may still temporarily delay read APIs. They do not block editor saves,
which are independent filesystem operations. Fully nonblocking read
API behavior for large Vaults will require cooperative time-slicing or
immutable-copy parsing workers, not concurrent SQLite access.

## Layer 3: disposable in-memory link cache

Durable document heads, object hashes, recovery snapshots and journal
remain the source of truth. A `VaultLinkGraph.Snapshot` keeps
per-revision parsed links, headings, blocks, aliases and ready-to-page
forward and reverse mention arrays in memory.

Each scan invalidates the visible link-cache generation. A scheduled
low-priority refresh compares document IDs, revision IDs, hashes and
lengths. Unchanged documents reuse parsed syntax and do not read their
immutable objects again; changed documents are parsed from verified
SHA-256 objects. All links are re-resolved when a namespace changes,
and the new graph is published in one step. Failed cache construction
never exposes a partially refreshed set of backlinks.

`VaultRuntime.links` is now a memory-only paginated query: no
SQLite scan, Markdown parsing, or object file reads on an HTTP request.
While the cache is pending it returns HTTP 503 `link_index_pending`;
oversized graphs return HTTP 413. `GET /v1/status` exposes
`linksIndexed` and `linkCacheGeneration`. Repeated GETs
and periodic no-op scans leave the generation unchanged. Status additionally
reports linkCacheProgress (processedHeads, totalHeads, resolvedHeads)
during a pending cooperative rebuild.

The cache is not written to `.andesite/vault.json`, SQLite or any
separate cache database. Closing/crashing the watcher discards it safely.

## Verification

- `VaultWorkSchedulerTests.swift` checks burst coalescing, scan
  priority, bounded retry, periodic recovery and snapshot priority.
- `VaultLinkCacheTests.swift` checks 30 repeated reads without
  reparsing, zero reparses for unchanged heads, exactly one parse for
  one changed head, deletion invalidation and oversized failure.
- The real-watch `VaultLocalHTTPTests.swift` fixture checks that
  25 repeated HTTP backlink reads keep the same cache generation,
  then sees a changed note reflected after FSEvents reconciliation.
- Run `swift test` and `scripts/test-api-server.sh`,
  plus Release build and smoke before shipping.

This is a backend responsiveness and safety improvement, not complete
Obsidian parity. Conditional existing-note edits are covered in
andesite-conditional-edit.md.
Full link resolution, unlinked mentions, Properties, Bases, Canvas,
editor UI and plugins remain tracked in
`docs/obsidian-compatibility.md`.

## External replication scheduling

The background job queue is still the owner of local scanning/indexing;
transport logic is intentionally separate. A host app can schedule
bounded immutable history exports and async upload after a successfully
committed revision (not on every keystroke), but no unconditional
always-running network process is installed. The CLI offers explicit
`sync-push`. An eventual app worker should wake on new durable
change sequences or snapshots and resume using persistent peer receipts.
Remote archive contents are never applied as filesystem edits by this
queue. See [backend and archive protocol](andesite-backend-and-sync.md).
