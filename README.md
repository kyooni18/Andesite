# Andesite

Andesite is a local-first backend for Markdown vaults, compatible with
Obsidian. It records every version of every file, recovers from crashes,
indexes notes for search, links, tags and properties, and synchronises
vaults with each other over authenticated HTTP.

There is one implementation, `VaultRuntime` in `AndesiteCore`. An app embeds it
through `VaultSession`. The `andesite-server` CLI, the HTTP server and the sync
client all call the same `VaultSession`.

- [docs/architecture.md](docs/architecture.md): how it works, guarantees and
  limitations
- [docs/http-api.md](docs/http-api.md): the HTTP API

## Build and test

Requires Swift 6 and macOS 14 or Linux (glibc; tested with `swift:6.2-noble`).

```sh
swift build -c release
swift test                    # unit, integration and two-vault HTTP tests
scripts/test-api-server.sh    # CLI + HTTP server smoke test, including SIGKILL/restart
scripts/test-sync-server.sh   # two servers syncing over HTTP
scripts/test-linux.sh         # the suite on Linux in Docker, including a real full-disk test
scripts/benchmark.sh 10000    # timings on a generated vault
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
