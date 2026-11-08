# Andesite authenticated local HTTP server

The HTTP API is written in Swift 6 using the pinned Hummingbird 2.28.0
dependency. It listens on **127.0.0.1 only** and serves authenticated,
GET-only access to the existing single-owner Vault index and snapshots.
It does not expose restoration, file mutation, SQL access, or sync.

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
| `/v1/status` | Vault catalog/readiness |
| `/v1/search?q=phrase&limit=50` | FTS hits with stable document/revision IDs |
| `/v1/snapshots?path=note.md&limit=50&offset=0` | Snapshot history metadata |
| `/v1/snapshots?document=ID` | History of one document |
| `/v1/snapshots/ID` | Verified snapshot metadata |
| `/v1/snapshots/ID/content` | Verified Markdown bytes, at most 1 MiB |

The payload format and resource limits follow the existing
[private Unix-socket API](andesite-local-http.md).

Missing or invalid authentication returns 401. Other HTTP methods return
405. GET requests with body/upload or upgrade indicators return 400.
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
runs off NIO event loops. The bridge never forwards arbitrary headers,
credentials, request bodies or mutating HTTP methods to the backend.

The bridge verifies the response status, content length and content type
and caps the entire reply at 1.1 MiB. If the watcher stops, the server
fails closed with 503 instead of serving a stale cache. The owner watcher
remains solely responsible for all SQLite and filesystem operations.

This API requires macOS 14 or later for the pinned Hummingbird version.
Other existing macOS 13 CLI features remain buildable. Remote access,
authorization policy for multiple users, mutation endpoints, subscription
streams and full sync are deliberately deferred.

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
