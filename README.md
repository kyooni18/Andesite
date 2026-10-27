# AndesiteServer (incomplete)

This repository is not a usable server. The executable intentionally exits with
an error instead of serving requests: authentication, recovery and the storage
engine are not implemented. Do not use it with real vaults.

The current milestone provides a Swift 6 package and an experimental SQLite
connection wrapper. It verifies SQLite >= 3.35, WAL and FTS5 at connection
startup, enables foreign keys and FULL synchronous mode, and supports bound
text statements and rollback on transaction failure. Callers must serialize
access and move blocking I/O off network event loops. This is not yet the
operational database or a filesystem/SQLite recovery protocol.

## Build and test

Install Swift 6.2 or later, SQLite development headers, pkg-config, and SQLite
with FTS5. Run `swift build` and `swift test`. The resolved dependency versions
are checked in. Hummingbird 2.28.0 and swift-markdown 0.9.0 are pinned; the
transitive swift-collections version is constrained to 1.3.0 because 1.7.5
failed with the locally installed Swift 6.4 prerelease toolchain.

The package has been built and its SQLite test run on macOS arm64 with the
local Swift 6.4 toolchain, and in the `swift:6.2` Linux arm64 container with
`libsqlite3-dev`. The local macOS build linked Homebrew's SQLite and emitted a
minimum deployment target warning; compatibility with older macOS releases has
not been verified. Linux filesystem guarantees and server behavior are not
verified by the SQLite test.

Additional experimental primitives include descriptor-relative, no-follow,
bounded two-observation vault reads and a SHA-256 object store. Reads reject
hard-linked files, mount crossings and unsafe path components; an observed
change between reads is rejected. These checks do not provide an atomic view
or capture edits that were never observed. The object store verifies hashes,
never replaces existing objects and syncs new contents and the directory, but
currently requires a trusted pre-existing private directory, buffers objects in
memory, and does not handle orphan cleanup, quotas or a database journal. No
code connects these primitives to a catalog or writes to vaults. They are not a
recovery implementation, and no power-loss or filesystem qualification tests
have been performed.

`CatalogSchema` provides a transactional, versioned **subset** of the core
catalog: vaults, entries, revisions, object metadata, changes and operation
reservations. It refuses a newer schema and rolls back a failed migration. It
is not yet an operational sync database: pending journals, conflicts,
tombstones, snapshots, leases and indexes are missing, as are catalog APIs and
process locking. The migration must not be run against production data without
exclusive ownership and a backup.

An experimental process-lock primitive uses an OS advisory lock on a no-follow
lock file in a trusted private state directory. It is not yet connected to
server startup and cannot detect the same vault configured under another state
directory. It never locks files against ordinary external editors.

A limited swift-markdown AST extractor validates UTF-8 and returns headings
and ordinary link destinations without altering the input. It is not the v1
Markdown indexer: frontmatter, wiki syntax, tags, slugging, link resolution,
GFM conformance fixtures and full v1 indexing remain to be implemented.

A preliminary SQLite FTS index can index supplied revision bytes and search a
bounded literal phrase within a vault. It atomically checks the current head
before committing and hides stale results. It currently indexes raw Markdown,
not fully extracted document text; the caller must supply bytes from the correct
verified immutable revision. It is not wired to ingestion or an API and lacks
index generations, backlinks, pagination, snippets and index watermarks.

An experimental explicit single-file external capture connects stable reads,
the object store, and catalog revisions/change events in a SQLite transaction.
It preserves earlier captured objects across updates and does not write vault
files. A failed database transaction leaves the catalog unchanged and may leave
an unreferenced object. This is **not reconciliation**: it has no watcher,
scan, deletion inference, rename handling, quarantine/incidents, or automatic
retry. It only accepts ASCII paths pending the specified portable Unicode key;
callers must hold the process lock and serialize vault access. Invalid UTF-8 is
rejected rather than published, but is not yet durably recorded as an incident.
No server route or background service uses this experimental primitive.
