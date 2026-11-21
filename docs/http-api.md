# HTTP API

`andesite-server serve <vault> [--port 8788]` listens on 127.0.0.1. Every
request needs `Authorization: Bearer <token>`, where the token is the
`ANDESITE_API_TOKEN` the server was started with. Browsers use a session
cookie on `/v1` instead (see [Browser sessions](#browser-sessions)). Revisions
are 32-hex-digit IDs. Writes require the current revision, or `If-None-Match: *` to create.

The server answers as soon as it starts. Document and index routes run as
user requests, ahead of indexing and sync; sync routes run as background
work (see [architecture.md](architecture.md#scheduling)). Until the first
scan completes, index routes return 503 `index_not_ready`.

Every `/v1` response has a JSON Schema in [schemas/](schemas/README.md); the
server tests validate real responses against them.

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

## Bookmarks

The vault's bookmarks, in the format of Obsidian's Bookmarks plugin
(`{"items": [...]}`; see `Bookmark` in AndesiteCore). They live in
`.obsidian/bookmarks.json` when the vault has an `.obsidian` folder, and in
`.andesite/bookmarks.json` otherwise. Moving a file or folder through the API,
by sync or outside the app moves its bookmarks along.

| Route | Request | Response |
|---|---|---|
| `GET /v1/bookmarks` | | the list, `ETag: "<version>"` (`"none"` before the file exists) |
| `PUT /v1/bookmarks` | the whole list; `If-Match: "<version>"` | the list and its new `ETag`; 412 `revision_conflict` if it changed |

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
| 401 | `authentication_required` | missing or wrong token, or an unknown or expired session |
| 403 | `client_header_required` | a cookie-authenticated change without `X-Andesite-Client: web` |
| 404 | `not_found`, `vault_not_found` | |
| 409 | `already_exists`, `history_gap`, `missing_object` | |
| 412 | `revision_conflict` with `current` | the document changed; read it again |
| 413 | `too_large` | over the size limit |
| 422 | `unsupported` | for example invalid UTF-8 or unparsable frontmatter |
| 503 | `index_not_ready` | the first scan has not finished, the last scan failed, or the vault is closing |
| 507 | `storage_full` | disk or quota full; see architecture.md |

A bundle is a sequence of frames, one per object: the 64-character hex hash,
the object's length as 8 bytes big-endian, then its bytes. Each object is
checked against its hash before it is stored.

## Several vaults

`andesite-server serve-all <folder> --state <dir>` serves every folder inside
`<folder>` as its own vault (hidden folders excepted), opening each when it is
first used. Each vault's whole API is mounted under its name, using the same
route definitions as `serve`:

- `/v1/vaults/<name>/…` is every `/v1` route above (for example
  `GET /v1/vaults/Work/file?path=a.md`);
- `/sync/vaults/<name>/…` is every sync route;
- `/v1/…` and `/sync/…` mean the vault named `main`.

Names are percent-encoded in the URL. An unknown vault is 404
`vault_not_found`; a name that cannot be a vault (a leading dot, a slash) is
400 `invalid_vault_name`.

| Route | Purpose |
|---|---|
| `GET /sync/vaults`, `GET /v1/vaults` | `{"vaults": [{"name": …}]}`; the same list, the second one reachable with a browser session |
| `POST /sync/vaults` `{"name": …}` | add an empty vault; 201, or 409 when it exists |

## Browser sessions

A web page must not keep the long-lived API token, so it trades the token for
a cookie once and the token is forgotten.

| Route | Request | Response |
|---|---|---|
| `POST /auth/session` | `{"token": "<api token>"}` | 201 `{"expiresIn": seconds}` and `Set-Cookie`; 401 for a wrong token |
| `DELETE /auth/session` | | 204; expires the cookie in the browser |
| `DELETE /v1/session` | cookie and `X-Andesite-Client: web` | 204; ends the session on the server |

- The cookie is `andesite_session=<64 hex digits>; Max-Age=604800; Path=/v1;
  HttpOnly; Secure; SameSite=Strict`. The ID is random and kept in memory, so
  sessions end when the server restarts, after seven days, and when more than
  256 newer sessions exist. `Secure` means browsers send it over HTTPS only
  (and to `localhost`): put TLS in front of any non-local deployment.
- `/v1` accepts the bearer token **or** the cookie. The cookie is valid on
  `/v1` only; `/sync` and `/auth` never accept it.
- With the cookie, any method other than GET, HEAD and OPTIONS also needs the
  header `X-Andesite-Client: web`; otherwise 403 `client_header_required`.
  A cross-origin page can not send that header without a CORS preflight, which
  this server never approves. A request that has the bearer token needs no
  header.
- The cookie's `Path=/v1` means a browser does not send it to `/auth/session`,
  so `DELETE /auth/session` can only expire the cookie client-side. To end the
  session on the server too, call `DELETE /v1/session` first. A client that
  does send the cookie to `/auth/session` ends the session there as well.
- Tokens are compared in constant time (the whole token, whatever the
  length of the guess).
