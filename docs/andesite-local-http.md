# Andesite read-only local HTTP API (macOS)

Andesite implements a small **same-user, read-only** HTTP/1.1 API over a
Unix domain socket inside the running FSEvents watcher. This is not the
Hummingbird loopback server, multi-user authentication or v1 sync protocol.
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

## Read-only endpoints

All methods except GET are rejected. Every response sends
`Cache-Control: no-store`, no persistent HTTP connection and no
network listener.

| Endpoint | Result |
| --- | --- |
| `/v1/status` | Catalog state, counts, open incidents, unfinished mutations, indexed readiness |
| `/v1/search?q=phrase&limit=50` | Literal-phrase search hit IDs, revision IDs and heading titles |
| `/v1/snapshots?path=note.md&limit=50&offset=0` | Newest-first snapshot metadata and pagination counts |
| `/v1/snapshots?document=ID` | Snapshot history for a stable document ID |
| `/v1/snapshots/ID` | Verified metadata for one snapshot |
| `/v1/snapshots/ID/content` | Exact Markdown bytes of that snapshot, when at most 1 MiB |

The list endpoint permits no selector to browse all snapshot metadata.
Limit is 1-100; offset is 0-100000. Larger snapshot content returns HTTP
413; use the existing export command with the watcher stopped.
Metadata and search responses use JSON, and content is exact UTF-8 Markdown.

HTTP 400 indicates a malformed request, 404 an unknown route or snapshot,
405 a non-GET method, and 503 a pending scan, unavailable index, quarantine
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
have a bounded send budget. Bodies, uploads and protocol upgrades are rejected.
Response JSON escapes user-controlled paths and titles; internal exceptions
do not expose SQL or filesystem details to the caller.

No endpoint edits the source vault, restores a snapshot, changes retention,
resolves a quarantine, prunes objects or retires journal artifacts.
A second Andesite CLI process still cannot open the state while the watcher
holds the exclusive lock; use the Python client for reads, and stop the watcher
for maintenance operations.

## Current limitations

There is no multi-client HTTP concurrency, streaming, HTTP keep-alive,
subscriptions, TCP/TLS transport, network authentication, Linux watcher or
remote synchronization. Listing currently gathers the catalog snapshot list
before applying limit and offset, so huge histories need query-level
pagination optimization. Kernel event overflow and actual storage power-loss
durability have not been qualified. Snapshot capture cannot reconstruct
unobserved intermediate edits.
