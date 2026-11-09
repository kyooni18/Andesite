# HTTP API

`andesite-server serve <vault> [--port 8788]` listens on 127.0.0.1. Every
request needs `Authorization: Bearer <token>`, where the token is the
`ANDESITE_API_TOKEN` the server was started with. Revisions are 32-hex-digit
IDs. Writes require the current revision, or `If-None-Match: *` to create.

The server answers as soon as it starts. Document and index routes run as
user requests, ahead of indexing and sync; sync routes run as background
work (see [architecture.md](architecture.md#scheduling)). Until the first
scan completes, index routes return 503 `index_not_ready`.

## Documents

| Route | Request | Response |
|---|---|---|
| `GET /v1/status` | | catalog state, counts |
| `GET /v1/file?path=` | | content (streamed), `ETag: "<revision>"` |
| `PUT /v1/file?path=` | body; `If-None-Match: *` (create) or `If-Match: "<rev>"` | document JSON (201 on create) |
| `DELETE /v1/file?path=` | `If-Match` | document JSON |
| `POST /v1/move` | `{path, to, revision, updateLinks?}` | document JSON |
| `POST /v1/restore` | `{path, revision}` | document JSON |
| `GET /v1/history?path=` | | revisions |
| `POST /v1/directories` | `{path}` creates; `{path, to, updateLinks?}` moves | `{path}` |

## Index

| Route | Request | Response |
|---|---|---|
| `GET /v1/documents` | `limit, offset, tag, property, value` | documents page |
| `GET /v1/search` | `q, limit, tag, property, value` | ranked results |
| `GET /v1/tags`, `GET /v1/properties` | `limit, offset` | tag / property browser |
| `GET /v1/metadata?path=` | | parsed properties and tags |
| `GET /v1/links?path=&direction=outgoing\|incoming` | `limit, offset` | links with `status` (resolved, ambiguous, missing, external) and `fragmentStatus` |
| `GET /v1/mentions?path=` | | unlinked mentions |
| `POST /v1/properties` | `{path, name, value, revision}`; value is a string, number, bool, string list or null (remove) | document JSON |
| `POST /v1/tags` | `{path, revision, add}` or `{path, revision, remove}` | document JSON |

## Snapshots

`GET /v1/snapshots?path=` lists recovery snapshots.
`GET /v1/snapshots/{id}/content` returns a snapshot's content.

## Sync

These routes are used by `SyncClient`; see [architecture.md](architecture.md#sync).

| Route | Purpose |
|---|---|
| `GET /sync/identity` | vault ID and epoch |
| `GET /sync/changes?after=&limit=&wait=` | revision feed page; with `wait` (seconds, at most 55) the reply is held until the feed moves past `after` |
| `POST /sync/changes` | receive a batch from a peer, then resolve it |
| `POST /sync/objects/missing` | which of the given objects are absent or partial |
| `POST /sync/objects/fetch` | whole objects (each at most 1 MiB) for a JSON list of hashes, as a bundle of at most 4 MiB |
| `POST /sync/objects/bundle` | store a bundle of whole objects; replies `{"received": n}` |
| `GET /sync/objects/{hash}?offset=&length=` | object chunk (at most 4 MiB) |
| `PUT /sync/objects/{hash}?size=&offset=` | upload a chunk; optional `X-Chunk-SHA256` header |

## Errors

Errors return `{"error": code}`:

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_path`, `invalid_query`, `invalid_json`, `invalid_sync_batch` | bad request |
| 401 | | missing or wrong token |
| 404 | `not_found` | |
| 409 | `already_exists`, `history_gap`, `missing_object` | |
| 412 | `revision_conflict` with `current` | the document changed; read it again |
| 413 | `too_large` | over the size limit |
| 422 | `unsupported` | for example invalid UTF-8 or unparsable frontmatter |
| 503 | `index_not_ready` | the first scan has not finished, the last scan failed, or the vault is closing |
| 507 | `storage_full` | disk or quota full; see architecture.md |

A bundle is a sequence of frames, one per object: the 64-character hex hash,
the object's length as 8 bytes big-endian, then its bytes. Each object is
checked against its hash before it is stored.
