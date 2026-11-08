# Andesite authenticated local HTTP server

The HTTP API is written in Swift 6 using the pinned Hummingbird 2.28.0
dependency. It listens on **127.0.0.1 only** and serves authenticated,
GET access to the existing single-owner Vault index and snapshots,
plus one revision-conditional Markdown edit route. It does not expose
creation, deletion, restoration, arbitrary file paths, SQL access or sync.

## Run

First open the selected Vault in another terminal:

```sh
cd /Users/example/Code/Andesite
swift build
.build/debug/andesite-server vault-watch /absolute/path/to/vault
```

In a second terminal, generate a 32-byte random token (64 hex digits)
and start Hummingbird on the loopback interface:

```sh
export ANDESITE_API_TOKEN="$(openssl rand -hex 32)"
.build/debug/andesite-server api-serve /absolute/path/to/vault --port 8788
```

Use the same token in a client shell:

```sh
curl -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
  http://127.0.0.1:8788/v1/status
curl -G -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
  --data-urlencode "q=search terms" \
  http://127.0.0.1:8788/v1/search
```

Do not put the token in the Vault marker, source control or a URL.
The server requires it in the environment and never saves it.
When the Vault watcher was started with an explicit private state path,
the server accepts `--state /absolute/private/state` as well.
It never opens an independent SQLite database. The watcher must respond
before Hummingbird binds TCP.

## Version 1 GET endpoints

| Path | Result |
| --- | --- |
| `/v1/documents?limit=50&offset=0` | Paginated live Markdown document metadata and stable IDs; optional tag/property/value AND filters |
| `/v1/documents/ID` | Indexed head metadata, headings, Markdown destinations and lexical wikilinks |
| `/v1/documents/ID/content` | Current immutable Markdown bytes (up to 1 MiB) |
| `/v1/documents/ID/links?limit=50&offset=0` | Outgoing lexical Markdown and wikilink references with conservative note/anchor resolution |
| `/v1/documents/ID/backlinks?limit=50&offset=0` | Inbound resolved mentions from verified indexed Markdown notes, with pagination |
| `/v1/tags?limit=50&offset=0` | Canonical frontmatter/inline tag summary with document counts |
| `/v1/properties?limit=50&offset=0` | Indexed YAML property keys, observed types and document counts |
| `/v1/documents/ID/properties` | Revision-aligned typed YAML properties, tags and diagnostics |
| `/v1/status` | Vault catalog/readiness |
| `/v1/search?q=phrase&limit=50` | FTS with optional tag/property/value filters, limited Obsidian tag:/[property:value] syntax |
| `/v1/snapshots?path=note.md&limit=50&offset=0` | Snapshot history metadata |
| `/v1/snapshots?document=ID` | History of one document |
| `/v1/snapshots/ID` | Verified snapshot metadata |
| `/v1/snapshots/ID/content` | Verified Markdown bytes, at most 1 MiB |

Document listing is path-sorted. Detail extraction exposes raw CommonMark
headings and link syntax, including Obsidian wikilinks, embeds, aliases and
anchors. The separate link endpoints resolve unambiguous current Markdown
note targets and linked backlinks, but not unlinked mentions or all
Obsidian link/refactoring semantics.
Document structure extraction is limited to notes of at most 256 KiB,
and caps each list at 256 entries with a structureTruncated flag. For notes
larger than 1 MiB, metadata is available but body retrieval is unavailable. Compare gaps in the
[Obsidian parity register](obsidian-compatibility.md).

Link endpoints return `mentions`, `total`,
`offset`, `nextOffset`, and scope metadata. Each
mention includes `source`, `sourcePath`,
`target`, `fragment`, `display`,
`syntax`, `embed`, a resolution status, optional
canonical `document` and `path`, an independent
`fragmentStatus`, and non-authoritative
`aliasSuggestions`. Status is one of resolved, missing,
ambiguous, unsupported or external. A file may be resolved while its
heading/block fragment remains missing or ambiguous.

Backlinks are prepared by the work scheduler **after** a successful
filesystem reconciliation, not parsed again on every GET. Unchanged
revisions reuse their parsed syntax and the fully resolved, immutable
forward/backlink arrays are published atomically in memory.
GET /v1/status includes linksIndexed and linkCacheGeneration.
Pending cache work returns HTTP 503 link_index_pending.

This does not yet support Obsidian's unlinked mentions, attachments,
full YAML Properties, smart link suggestions, rename rewrites or all
heading/block path forms. Oversized graphs return HTTP 413 rather
than incomplete empty results: maximum 2000 documents, 24 MiB total,
256 KiB per note, 20000 references total, and 512 per note.
No source note is modified by refresh. The serial cache refresh can
still delay read APIs for large Vaults; see
[work scheduler architecture](andesite-work-queue.md).

One narrow write route is also supported: PUT /v1/documents/ID/content.
It requires the same bearer token, a quoted exact If-Match revision
from GET /v1/documents, Content-Type text/markdown; charset=utf-8,
and at most 256 KiB of full Markdown bytes. It uses the same durable
preimage/APFS-exchange journal as restoration; it does not overwrite
unobserved external edits. The returned state has indexReady=false
until the subsequent scan and cache jobs complete. All other mutating
methods are rejected. See
[conditional edit and recovery](andesite-conditional-edit.md).

YAML metadata is derived from current immutable indexed Markdown heads.
The Yams parser recognizes typed properties and normalized Unicode tags,
with case-insensitive nested-tag matching. A v8-v9 migration backfills
the metadata from historic immutable objects; no note is rewritten.
Malformed YAML is flagged explicitly instead of indexing a partial map.
Advanced Obsidian query expressions and the property editor are not
implemented. Details: [Obsidian YAML, tags and query API](andesite-obsidian-metadata.md).

The payload format and resource limits follow the existing
[private Unix-socket API](andesite-local-http.md).

Missing or invalid authentication returns 401. Unsupported methods return
405. GET requests with body/upload or upgrade indicators return 400.
Stale If-Match yields 412, a conflicting live edit yields 409, missing
preconditions yield 428, invalid UTF-8 yields 422, oversized upload 413.
Out-of-scope routes return 404; unavailable watcher or index gives 503.
Responses include `Cache-Control: no-store` and
`X-Content-Type-Options: nosniff`.

## Security and concurrency

This is **not a remote or public HTTP service**. The listener binds only
127.0.0.1; it has no TLS, CORS, LAN accessibility, or multi-user
authorization. It requires a 64-hex-character bearer token, compared
bytewise over the entire fixed-length value. Since it uses unencrypted
HTTP, do not make it public or tunnel it over an untrusted network.

Hummingbird and the snapshot engine execute in different processes. The
HTTP route delegates a bounded GET operation through a Swift actor to
the watcher's private same-UID Unix socket. The actor permits one
in-flight backend query and rejects concurrent attempts with 503 rather
than creating a second writer or unbounded queue. Synchronous socket I/O
runs off NIO event loops. The bridge never forwards arbitrary headers or bearer credentials.
Its PUT transport is restricted to a single exact-document edit route
with a version precondition and bounded Markdown body; no other
mutation methods reach the backend.

The bridge verifies the response status, content length and content type
and caps the entire reply at 1.1 MiB. If the watcher stops, the server
fails closed with 503 instead of serving a stale cache. The owner watcher
remains solely responsible for all SQLite and filesystem operations.

This API requires macOS 14 or later for the pinned Hummingbird version.
Other existing macOS 13 CLI features remain buildable. Remote access, multi-user authorization, general mutation endpoints,
subscription streams and full sync are deliberately deferred.

## Test

```sh
swift build
swift test
scripts/test-api-server.sh
swift build -c release
```

The integration script creates only a temporary Vault, watcher and
Hummingbird process. It tests authenticated search, snapshot content,
invalid tokens and methods, request body refusal, loopback-only binding
and failure after watcher shutdown. No real Vault is opened, and no
background service is left running.
