# One Swift backend: embedded app, standalone server and peer archive

Andesite has **one** synchronous Swift source of truth, `VaultRuntime`
inside `AndesiteCore`. An app and a server do not implement
independent parsers, scanners or mutation semantics.

## Backend/API boundary

An in-process host opens a `VaultSession` and uses its
`AndesiteBackend` facade for documents, typed metadata, search,
snapshots, conflict-aware edits and sync operations. This does not
start HTTP or create an additional SQLite connection.

```swift
let session = try VaultSession(vaultDirectory: "/absolute/vault")
_ = try session.reconcile()
let backend = try session.backend
let notes = try backend.documents()
let pending = try backend.syncChanges(after: 0)
try session.close()
```

`AndesiteBackend` is intentionally **not Sendable**; the host
must call it on the Vault's single serial backend executor. The
session must remain open until all backend operations have finished.
The app handles UI debouncing and scheduling (e.g. 2 seconds after the
last keystroke, with a maximum 5-second delay for continuous typing).
The backend only receives a **complete changed note** at save time;
it does not write one disk revision per keystroke.

A headless server runs
`andesite-server vault-watch /vault`, which owns the same
`VaultRuntime` and its private state. The optional
`andesite-server api-serve /vault` Hummingbird sidecar authenticates
requests and forwards them over the same-user AF_UNIX socket to a
`VaultLocalHTTP` adapter of `AndesiteBackend`.
This adds **no second indexer or independent SQLite owner**. The
HTTP API maps directly to existing backend methods; it is not
the engine.

The public HTTP sidecar intentionally binds **127.0.0.1 only**. To
serve it to other machines, an operator must provide authenticated
TLS termination or a secure tunnel. The client refuses plain HTTP to
non-loopback destinations; the user must configure `ANDESITE_API_TOKEN`
and should use a separately provisioned secret per receiving server.
There is no anonymous public Internet listener or multi-tenant
authorization policy.

## Replication model (currently archive-first)

A committed local edit or external file observation creates a
monotonic sequence in `changes` with a Vault ID and
an immutable epoch. A local app/server can export source events and
their SHA-256 verified revision objects without re-scanning the
physical Markdown directory. Recovery snapshots are transported
separately, since snapshot creation can happen *after* a change event
(e.g. during shutdown).

The origin's `sync_outgoing_peers` persists the **last
acknowledged change sequence per destination-bound remote peer**. The
`sync_outgoing_snapshots` set remembers which exact snapshot
IDs the peer has confirmed; it does not assume that advancing the
change cursor means all snapshots have been uploaded. Both records
survive shutdown and network interruptions.

The receiver stores remote events, immutable content and snapshots
in isolated `sync_inbox_changes` and
`sync_inbox_snapshots` tables, keyed by originating Vault
and epoch. It accepts contiguous event sequences, verifies hashes,
rejects incompatible replays and acknowledges a packet only after a
SQLite transaction commits. Re-uploading an identical packet is
idempotent. The receiving Vault's **active documents and snapshots
remain unchanged** until an explicitly implemented, conflict-aware
apply/reconcile operation exists.

This is a working peer-to-peer **history transfer and archive
transport**, not yet automatic collaborative/mirror synchronization.
It is intentionally safer than replaying arbitrary remote events
against the filesystem.

### HTTP API, same authenticated server

- `GET /v1/sync/changes?after=0&limit=8` — immutable
  local source change feed with content hashes and bounded data
- `GET /v1/sync/snapshots/SNAPSHOT_ID` — local recovery
  snapshot and verified immutable payload
- `POST /v1/sync/changes` — validate/archive a remote
  event batch, return its acknowledged cursor
- `POST /v1/sync/snapshots` — validate/archive a single
  recovery snapshot, return replay/storage state
- `GET /v1/sync/inbox` — list archived remote Vaults,
  epochs, received sequence positions and snapshot counts
- `GET /v1/sync/inbox/changes?source=32HEX&epoch=32HEX&after=0`
  — read back archived, SHA-256 verified change events
- `GET /v1/sync/inbox/snapshots?source=32HEX&epoch=32HEX`
  — page archived snapshot identifiers and hashes
- `GET /v1/sync/inbox/snapshots/SNAPSHOT_ID?source=32HEX&epoch=32HEX`
  — read back a verified archived snapshot

Events and snapshot bytes are transported with protocol version 1
and encoded as bounded JSON/base64. Each packet is limited to
256 KiB; individual inline objects are limited to 128 KiB and a
change packet to 16 events. **Larger attachments or notes are not
silently skipped**: the upload refuses them until chunked
content-addressed transfer is implemented. For production-scale
Vaults this chunked transport, quotas and garbage collection
will be necessary.

### Upload from a headless local Vault

Stop **that Vault's** watcher first; only one process may own
the source catalog state. The receiving server's watcher and API
remain running. In a shell with the remote server's token:

```sh
export ANDESITE_API_TOKEN="64_HEX_DIGITS_FROM_REMOTE_SERVER"
.build/debug/andesite-server sync-push /absolute/source-vault \
  --to https://remote.example \
  --peer trusted-backup-1
```

Optional flags: `--state /absolute/private-state` for a
specific pre-existing state and `--changes-only` to skip
snapshot upload. Resuming uses durable destination-bound per-peer cursor and per-snapshot
receipts, not an external list of files. Rerunning a completed push
sends no already-acknowledged changes or snapshots.

For local manual testing only, `--to http://127.0.0.1:PORT`
is allowed. Bare network HTTP, URL credentials, HTTP redirects and
arbitrary destination path prefixes are refused.

### Embedded app upload without closing the backend

The app calls `backend.syncChanges(after:limit:)` and
`backend.pendingSyncSnapshots(peer:limit:)` on its own serial
backend executor. A distinct asynchronous
`AndesiteHTTPSyncClient` uploads those **immutable value
objects**. When it receives a matching authenticated response, the
app schedules `backend.acknowledgeSync(...)` or
`backend.acknowledgeSyncSnapshot(...)` on the original backend
executor. This avoids a second SQLite owner and avoids keeping the
scanner blocked on network latency.

`AndesiteHTTPSyncClient.downloadIncomingChanges(...)` and
`downloadIncomingSnapshot(...)` can fetch verified archived
material for a future reconciliation UI/engine. They **do not**
write to the Vault or perform automatic conflict resolution.

## Security, failure modes and remaining work

- Only the explicitly authenticated user/service can upload note
  content; the in-process API cannot bypass VaultRuntime's filesystem
  and revision validation.
- Remote archives are separated by Vault ID and epoch, preventing
  accidental mixing of unrelated Vault histories.
- Hash mismatches, out-of-order events, incompatible same-sequence
  payloads, truncation and oversized inline objects are refused.
- Source files are not opened during feed serving: reads use the
  source's immutable revisions. The inbox is indexed/private state,
  not a path for remote filesystem writes.
- Physical storage is currently private SQLite state, **not end-to-end
  encrypted**. Hummingbird's loopback-only bearer token is not a
  substitute for production HTTPS/identity policy.
- **Not yet implemented:** authorized mapping of remote Vault IDs
  onto another device's Vault, parent-revision merge rules, conflict
  resolution UI, create/delete/rename application, tombstone GC,
  chunked large object upload, attachment sync, key exchange,
  sync quotas, live subscriptions, and scheduled automatic upload.
  Do not claim full Obsidian Sync compatibility.

## Verification

`AndesiteSyncArchiveTests.swift` exercises independent Vault
state, SHA-256 objects, durable source/receiver cursors, replay,
conflict rejection and snapshot upload bookkeeping. The
`scripts/test-sync-server.sh` creates two temporary Vaults,
runs a real authenticated Hummingbird receiver, uploads and resumes
via the Swift CLI transport, downloads archived changes and snapshots,
tests authentication, inspects the receiver catalog *after stopping
its owner* and proves the receiver's live document stayed unchanged.

Run `swift test`, `scripts/test-api-server.sh`,
`scripts/test-sync-server.sh` and `swift build -c release`
before shipping any API or database migration change.
