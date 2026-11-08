# Andesite same-user local HTTP API (macOS)

Andesite implements a small **same-user, bounded** HTTP/1.1 API over a
Unix domain socket inside the running FSEvents watcher. This is not the
Hummingbird loopback server or multi-user authentication; the separate
peer archive sync v1 contract is documented in
[backend architecture and archive transport](andesite-backend-and-sync.md).
The watcher itself opens no TCP port. The separate authenticated Hummingbird
sidecar is documented in [the HTTP server contract](andesite-http-server.md).

## Start and query it

Run `andesite-server watch --vault ABSOLUTE_VAULT --state ABSOLUTE_STATE`.
The watcher reports `watch-api socket=... transport=unix-http access=same-user`.
It retains the existing exclusive state lock.

Query while watch is running, without opening another SQLite connection:

```sh
cd /Users/example/Code/Andesite
python3 scripts/andesite-api.py --state /absolute/private/state status
python3 scripts/andesite-api.py --state /absolute/private/state search "phrase"
python3 scripts/andesite-api.py --state /absolute/private/state snapshots --path note.md
python3 scripts/andesite-api.py --state /absolute/private/state snapshot SNAPSHOT_ID
python3 scripts/andesite-api.py --state /absolute/private/state content SNAPSHOT_ID
```

For a short state path, curl works too:

```sh
curl --unix-socket /absolute/private/state/andesite-read.sock \
  'http://localhost/v1/search?q=phrase'
```

The socket is mode 0600. macOS Unix socket pathnames are limited to
104 bytes. For a longer state path, the server uses the stable per-UID
0700 directory:

``
/private/tmp/andesite-http-<uid>/<first-24-hex-of-SHA256(absolute-state-path)>.sock
``

The bundled Python client locates either form. To use curl in this case,
read the reported socket path in the watcher logs. On clean shutdown it
is unlinked; after SIGKILL it is reused only after acquiring the state
lock and verifying that the old path is a same-user Unix socket.

## Read endpoints (and bounded sync inbox POST)

All methods except GET are rejected. Every response sends
`Cache-Control: no-store`, no persistent HTTP connection and no
network listener.

| Endpoint | Result |
| --- | --- |
| `/v1/status` | Catalog state, counts, open incidents, unfinished mutations, indexed readiness |
| `/v1/tags?limit=50&offset=0` | Distinct canonical YAML/inline tags with document counts |
| `/v1/properties?limit=50&offset=0` | YAML property keys, observed type lists and document counts |
| `/v1/documents/ID/properties` | Revision-aligned typed properties and tags |
| `/v1/documents?limit=50&offset=0` | Paginated current Markdown heads |
| `/v1/documents/ID` | Current metadata, headings and raw link syntax |
| `/v1/documents/ID/content` | Exact current immutable Markdown bytes up to 1 MiB |
| `/v1/documents/ID/links` | Outgoing verified note targets, missing/ambiguous statuses and anchors |
| `/v1/documents/ID/backlinks` | Inbound resolved references from indexed Markdown, no unlinked mentions |
| `/v1/search?q=phrase&limit=50` | Literal-phrase search hit IDs, revision IDs and heading titles |
| `/v1/snapshots?path=note.md&limit=50&offset=0` | Newest-first snapshot metadata and pagination counts |
| `/v1/snapshots?document=ID` | Snapshot history for a stable document ID |
| `/v1/snapshots/ID` | Verified metadata for one snapshot |
| `/v1/snapshots/ID/content` | Exact Markdown bytes of that snapshot, when at most 1 MiB |

The list endpoint permits no selector to browse all snapshot metadata.
Limit is 1-100; offset is 0-100000. Larger snapshot content returns HTTP
413; use the existing export command with the watcher stopped.
Metadata and search responses use JSON, and content is exact UTF-8 Markdown.

HTTP 400 indicates a malformed request, 404 an unknown route, document
or snapshot, 405 a non-GET method, 413 an object/graph over the configured
safe read budget, and 503 a pending scan, unavailable index, quarantine
or integrity failure. Search responses reflect the **last successfully
reconciled catalog**, not an atomic live view of a note being edited. While
known FSEvents changes remain pending, search returns 503 rather than
deliberately serving a stale index. Unobserved concurrent editor changes
can still occur between checks. Previously verified snapshots may still be
read during quarantine, subject to object-store integrity checks.

## Trust and concurrency

The listener verifies the connecting process's macOS peer UID. State
storage is private (0700); the socket is mode 0600 and any fallback directory
is also private. This is authorization among OS users, **not isolation from
untrusted processes running under the same user**. Never proxy this socket
over TCP or expose its directory to another account.

All HTTP queries run on the watcher's single synchronous owner thread,
serialized with reconciliation, snapshot registration and journal recovery.
There is no additional SQLite connection, HTTP task executor or concurrent
database access. At most one accepted request is handled per loop. Headers
are bounded to 8 KiB, with a 200 ms absolute receive deadline, and responses
have a bounded send budget. GET request bodies and protocol upgrades are rejected. Only the
specific revision-conditioned Markdown PUT and replica archive POST
accept bounded request bodies, with separate content-type and length
validation.
Response JSON escapes user-controlled paths and titles; internal exceptions
do not expose SQL or filesystem details to the caller.

Only the existing-note revision-conditioned PUT modifies Vault
Markdown through its verified recovery journal. Archive POSTs
modify private replication inbox records only; they do not apply
remote content. No HTTP endpoint creates/deletes notes, restores a
snapshot, resolves quarantine, prunes objects or retires artifacts.
A second Andesite CLI process still cannot open the state while the watcher
holds the exclusive lock; use the Python client for reads, and stop the watcher
for maintenance operations.

## Current limitations

There is no multi-client HTTP concurrency, streaming, HTTP keep-alive,
subscriptions, built-in TCP/TLS endpoint, multi-tenant
remote authentication, Linux watcher or automatic remote merge/apply. Listing currently gathers the catalog snapshot list
before applying limit and offset, so huge histories need query-level
pagination optimization. Kernel event overflow and actual storage power-loss
durability have not been qualified. Snapshot capture cannot reconstruct
unobserved intermediate edits.

Link GETs use an in-memory graph refreshed at low priority by
VaultWorkScheduler after successful reconciliation. They do not parse
or scan on a request. GET /v1/status includes linksIndexed and
linkCacheGeneration; see [the scheduler architecture](andesite-work-queue.md).

A single, exact-revision conditional PUT is available at
/v1/documents/ID/content, accepting at most 256 KiB of Markdown.
It is processed on the VaultRuntime owner thread and uses the existing
durable mutation journal. See [conditional edit and recovery](andesite-conditional-edit.md). Other writes are rejected.

Typed YAML frontmatter and nested/inline Unicode tags are indexed with
the same current head revision as FTS. Document listing and search support
tag, property and value selectors. The query string additionally supports
a bounded tag:#project and [property:value] search subset. See
[Obsidian metadata API](andesite-obsidian-metadata.md); no source YAML
is modified by GET requests.

The same private socket also supports bounded GET for the local sync
feed, received-inbox status, and archived changes/snapshots, and
authenticated-sidecar POST for verified peer archive receipts.
See [backend modes and sync](andesite-backend-and-sync.md). The archive
never applies remote content to active Markdown files.
