# Andesite

Andesite is a local-first backend for Markdown vaults, compatible with
Obsidian. It records every version of every file, recovers from crashes,
indexes notes for search, links, tags and properties, and synchronises
vaults with each other over authenticated HTTP.

There is one implementation, `VaultRuntime` in `AndesiteCore`. An app embeds it
through the `Vault` class. The `andesite-server` CLI, the HTTP server and the
sync client all call the same `Vault`.

- [docs/architecture.md](docs/architecture.md): how it works, guarantees and
  limitations
- [docs/http-api.md](docs/http-api.md): the HTTP API

## Use it from Swift

Add the `AndesiteCore` library product. Opening a vault starts everything it
needs: the folder watcher, indexing, recovery snapshots and crash recovery.
Calls from your app run before background work, which pauses to let them in.

```swift
import AndesiteCore

let vault = try Vault(at: "/Users/me/Notes")
let note = try await vault.create("Ideas.md", "# Ideas\n")
try await vault.update("Ideas.md", "# Ideas\nSee [[Plans]]\n", revision: note.revisionID)
try await vault.move("Plans.md", to: "Projects/Plans.md",
                     revision: vault.document("Plans.md").revisionID)  // links are rewritten
let hits = try await vault.search("plans")
let backlinks = try await vault.links("Projects/Plans.md", direction: .incoming)
try vault.close()
```

Every change takes the revision it is based on and throws
`VaultError.conflict(current:)` if the document changed meanwhile. Index
queries throw `VaultRuntimeError.indexNotReady` until the first scan has
finished; `try await vault.refresh()` waits for a scan.

For finer control:

- `Vault.Options`: state directory, `watch: false`, watcher timing
  (`VaultMonitorSettings`), size limits, and a `report` callback for
  background events.
- `startWatching` / `stopWatching`, `refresh`, `collectGarbage`,
  `configureSnapshots`.
- `sync(with:token:)` once, or `startSyncing(with:token:every:)` in the
  background.
- `perform(.read | .write | .background) { runtime in ... }` (async) and
  `run` (blocking) to call `VaultRuntime` directly, with that priority.

## Build and test

Requires Swift 6 and macOS 14 or Linux (glibc; tested with `swift:6.2-noble`).

```sh
swift build -c release
swift test                    # unit, integration and two-vault HTTP tests
scripts/test-api-server.sh    # CLI + HTTP server smoke test, including SIGKILL/restart
scripts/test-sync-server.sh   # two servers syncing over HTTP
scripts/test-linux.sh         # the suite on Linux in Docker, including a real full-disk test
scripts/benchmark.sh 10000    # timings on a generated vault
scripts/latency.sh 10000      # request latency while indexing and during edits
```

All tests and scripts use disposable temporary vaults.

## CLI

```
andesite-server <command> <vault> [arguments] [--state <dir>]
```

Each vault needs a private state directory (mode 0700) outside the vault. It
holds the catalog (SQLite) and the content-addressed object store. `add`
records that location in `<vault>/.andesite/vault.json`, so later commands can
omit `--state`.

| Command | Purpose |
|---|---|
| `add`, `info`, `state`, `remove` | Manage the vault marker |
| `open` | Scan once (captures external edits) and exit |
| `status`, `search <query>` | Show catalog state; run a full-text search |
| `read <path>`, `history <path>` | Show content and revisions |
| `write <path> [<revision>]` | Create, or update at a revision (stdin) |
| `move`, `delete`, `restore` | Revision-checked document changes |
| `mkdir`, `mvdir` | Directory changes (moves update links) |
| `links <path> [incoming]`, `mentions <path>` | Outgoing links, backlinks, unlinked mentions |
| `tag <path> add\|remove <tag> <rev>`, `property <path> <name> <value>\|- <rev>` | Edit frontmatter |
| `snapshots`, `snapshot`, `snapshot-*` | Recovery snapshots |
| `gc [days]` | Remove unreferenced objects older than the grace period |
| `watch` | Watch the vault (FSEvents or inotify) and capture changes |
| `serve [--port N]` | `watch` plus the HTTP API on 127.0.0.1 |
| `sync <url> [--every S]` | Sync with a remote server, once or periodically |

`serve` and `sync` read the bearer token from `ANDESITE_API_TOKEN` (64 hex
digits, for example `openssl rand -hex 32`).

## Two vaults in sync

```sh
export ANDESITE_API_TOKEN=$(openssl rand -hex 32)
andesite-server serve ~/VaultA --state ~/.andesite/a --port 8790 &
andesite-server sync ~/VaultB http://127.0.0.1:8790 --state ~/.andesite/b --every 30
```

The server listens only on loopback. For another machine, put it behind a
TLS-terminating reverse proxy. The sync client refuses plain HTTP to any
address that is not loopback, and it does not follow redirects.

## Web app

The container serves a web app at `/` from `deploy/www`. The app is a separate project, written in
Mün: [kyooni18/Andesite-Mun](https://github.com/kyooni18/Andesite-Mun). Build it there and copy it
here with `pnpm run deploy ../Andesite/deploy/www`, then `docker compose up --build`. The browser signs
in with the API token once (`POST /auth/session`) and uses an HttpOnly session cookie from then on;
see [docs/http-api.md](docs/http-api.md#browser-sessions). The JSON Schemas of the `/v1` responses are
in [docs/schemas](docs/schemas/README.md) and the app generates its types from them.
