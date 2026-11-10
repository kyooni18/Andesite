# Architecture

## One owner

`VaultRuntime` (AndesiteCore) is the whole backend. It is synchronous and owns
one SQLite connection. `Vault` is the public Swift API: it owns the runtime and
runs every call on one thread per vault (`VaultExecutor`). Its async methods
(`create`, `search`, `links`, ...) are what an app calls; `perform` and `run`
give direct access to the runtime. The CLI, the HTTP server (`AndesiteHTTP`,
Hummingbird), the sync client and the watcher are all callers of one `Vault`.
A process lock in the state directory makes sure a second process cannot open
the same catalog.

## Scheduling

Each call is user work (`.read` or `.write`) or `.background` work. The
vault's thread runs:

1. User requests, in arrival order.
2. Queued background work (sync steps, `refresh`, garbage collection), then
   the watcher.

Background work that has waited 0.5 s runs next anyway, so steady traffic
cannot stall indexing. While background work runs, waiting user requests
enter at safe points outside transactions:

- **Reads** enter at any of them: between files, between folders while the
  vault is enumerated, while a scan waits for files to settle. They run with
  catalog writes refused (`PRAGMA query_only`).
- **Writes** enter between a scan's batches. A waiting write ends the batch
  early, and notes are parsed before the batch commits, so the write waits
  only for that batch's SQL.

A write that entered a scan may have changed what the scan saw. The scan
keeps its captures, leaves moves and deletions to the next pass and reports
itself incomplete; so does a scan that saw a file change while it ran. The
index stays usable meanwhile. The watcher scans again after the usual quiet
period; after three incomplete scans in a row, writes wait during the next
one, so moves and deletions are always applied. Sync and other background
work let reads in, not writes.

State directory (private, outside the vault):

- `catalog.sqlite`: entries, revisions, the change feed, mutation plans, the
  search and link index, snapshots and sync cursors. It uses WAL mode with
  `synchronous=FULL` and, on macOS, `fullfsync`. Opening the catalog runs
  migrations in one transaction and then `quick_check` and
  `foreign_key_check`.
- `objects/`: immutable content addressed by SHA-256. Content is verified by
  hash whenever it is exported, transferred or restored.

## Document lifecycle

Every change made through the API (create, update, move, delete, restore and
directory moves) is a **mutation plan**:

1. Record the intent.
2. Do the filesystem step: write a staged file and publish it atomically by
   rename or exchange.
3. Commit the catalog: the revision, the head, the search and link index, and a
   recovery snapshot.
4. Clean up.

Recovery, at the next operation or on restart, finishes or abandons each plan
from the same steps. Fault-injection tests kill the process at every step. A
change is rejected unless it is based on the current revision (optimistic
concurrency). Files are verified by fingerprint before they are replaced, or
by hash if the fingerprint changed.

External edits are captured by reconcile:

- It enumerates the vault and reads only files whose fingerprint (device,
  inode, size, mtime, ctime, birth time) differs from the catalog.
- It streams them into the object store after one quiet period.
- It commits them 256 at a time.
- Moves keep a document's identity when inode and birth time match. On Linux,
  birth time comes from `statx`.
- Files over the size limit (16 MiB for Markdown, 4 GiB for attachments) stay
  untracked and are not treated as deletions.

## Watching

`Vault` starts the watcher when it opens (unless `Options.watch` is false).
`VaultWatcher` runs on the vault's thread as background work:

- File events come from FSEvents on macOS and from recursive inotify on Linux.
  An inotify queue overflow, or a folder that can't be watched, triggers a
  rescan.
- A scheduler coalesces bursts: it waits 0.4 s after the last event, and at
  most 2 s while events keep arriving.
- The first scan starts at once; until it completes, index queries throw
  `VaultRuntimeError.indexNotReady` (HTTP 503). Document reads and writes
  work meanwhile.
- It retries failures with backoff and runs a fallback rescan every 5 minutes.
- The full catalog/object cross-check runs on a runtime's first scan and then
  at most every 5 minutes.

## Sync

Peers exchange revisions, not files:

1. **Pull:** the feed is the catalog's change log. A pull stores remote
   revisions and their objects, with resumable 4 MiB chunks published only
   when the hash matches. Receiving never touches files.
2. **Resolve:** after all pages are received, pending documents are resolved
   over their revision graph:
   - A fast-forward is applied as a normal mutation plan.
   - Concurrent text edits get a byte-exact three-way merge.
   - If the merge conflicts, the greater revision wins and the other version
     is kept as a conflict copy.
   - An edit beats a concurrent delete; a delete beats a mere move.
   - When two documents claim one path, the smaller ID keeps it and the other
     gets `name (conflict <id>).md`.
   - Identical content at one path is merged into one document.

   Merge revision IDs are derived from their parents, so both peers compute
   the same history and converge (a randomized fuzz test checks this).
3. **Push:** the local revisions go to the peer, which resolves them the same
   way.

Cursors and acknowledgements are persistent, so an interrupted or killed sync
resumes. The client requires HTTPS for non-loopback hosts. The server binds
127.0.0.1 and requires a bearer token (compared in constant time) for every
route.

## Obsidian

- **Links:** wikilinks (`[[a]]`, `[[a#h|alias]]`, `![[embed]]`, `[[#^block]]`)
  and Markdown links are lexed outside code. They are stored per revision with
  their byte positions, along with each note's headings and block IDs.
- **Link resolution** happens at query time against the live catalog. It
  matches an exact path, a unique name or path suffix (preferring the same
  folder), or a relative path. Ambiguous links are reported and never guessed.
  Backlinks, fragment status, attachment embeds and unlinked mentions
  (including aliases) come from the index.
- **Renames:** a file or folder move rewrites links that resolved to it. It
  also rewrites relative links inside moved notes. Each link keeps its style
  and gets the shortest unambiguous form. A rewrite is applied only if the new
  link resolves to the moved file. Notes changed in the meantime are skipped.
- **Properties and tags:** `setProperty`, `addTag` and `removeTag` replace only
  the lines of the edited key. They keep line endings and refuse to write
  frontmatter that would not parse. Inline `#tags` are prose and are left
  alone. `.obsidian/` and other hidden folders are never indexed or modified,
  except `bookmarks.json`, which Andesite shares with Obsidian's Bookmarks
  plugin and rewrites when a bookmarked file or folder moves.

## Reliability

- **Crashes:** mutation plans make every API change atomic and recoverable.
  The catalog commit is the point of no return.
- **Disk full:** `VaultError.isStorageFull` recognizes ENOSPC/EDQUOT and
  `SQLITE_FULL` from any layer, and HTTP answers 507.
  - A write rejected this way changes nothing visible, unless its file was
    already published. In that case recovery completes it later, as after a
    crash.
  - Reads keep working.
  - A test fills a real tmpfs and checks that acknowledged writes survive.
- **Garbage collection:** unreferenced objects older than the grace period
  are removed. Objects referenced by any revision, snapshot or pending plan
  are kept.

## Performance

Measured with `scripts/benchmark.sh` (release build, Apple silicon, generated
notes with 5 links each):

| | 2,000 notes | 10,000 notes |
|---|---|---|
| Initial scan and index | 5.8 s | 24.2 s |
| Rescan, nothing changed (CLI, incl. startup) | 0.25 s | 1.0 s |
| Search | 0.24 s | 1.0 s (CLI, incl. startup) |
| Rename with link updates | 0.26 s | 0.72 s |
| Peak memory | 38 MB | 120 MB |

Request latency over HTTP, measured with `scripts/latency.sh 10000` (10,000
notes; one read and one write about every 70 ms; the edits phase also appends
to a note every 50 ms). Before is the single serial queue (commit fdeb94d).

| | Before | Now |
|---|---|---|
| API reachable after start | 20.8 s (after the initial index) | 0.5 s |
| Read during initial index | unavailable | p95 8 ms, max 11 ms |
| Write during initial index | unavailable | p50 58 ms, p95 80 ms, max 0.39 s |
| Search during edits | 188 of 216 failed (503) during rescans; max 0.55 s | none failed; p95 32 ms, max 41 ms |
| Write during edits | p95 28 ms, max 53 ms | p95 42 ms, max 0.49 s |

Search itself takes about 30 ms at this size. The worst writes wait for one
whole scan pass that holds writes back (one in four under continuous
writes). The initial index took 34 s while serving these requests, against
25 s without them.

## Known limitations

- Every watcher scan stats the whole vault. Writes cannot enter while the
  folder is enumerated (about 0.2 s at 10,000 notes) or during a pass that
  holds them back, so the worst write waits about 0.5 s at that size.
- Swap cycles among pending sync entries are broken with a conflict-copy path,
  which can differ between peers.
- Inline body `#tags` are not edited. Link rewriting does not touch links
  inside HTML or callout syntax that the lexer does not recognize.
- A streamed `GET /v1/file` is not hash-checked while it streams.
- Moving a file over the size limit looks like a deletion of the tracked file.
- No built-in TLS. Use a reverse proxy for remote peers.
