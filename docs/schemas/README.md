# JSON Schemas for the HTTP API

One schema per `/v1` response (see [../http-api.md](../http-api.md)). They are the
data contract between the server and its clients:

- `Tests/AndesiteCoreTests/HTTPSchemaTests.swift` validates real responses from a
  running server against them.
- The web/desktop client (`kyooni18/Andesite-Mun`) generates its TypeScript types
  from them and validates recorded responses in its own tests.

| Schema | Route |
|---|---|
| `status.json` | `GET /v1/status` |
| `document.json` | `PUT /v1/file`, `POST /v1/move`, `/restore`, `/properties`, `/tags`; entries of `documents.json` |
| `deleted.json` | `DELETE /v1/file` |
| `directory.json` | `POST /v1/directories` |
| `history.json` | `GET /v1/history` |
| `documents.json` | `GET /v1/documents` |
| `search.json` | `GET /v1/search` |
| `tags.json`, `properties.json` | `GET /v1/tags`, `GET /v1/properties` |
| `metadata.json` | `GET /v1/metadata` |
| `links.json`, `mentions.json` | `GET /v1/links`, `GET /v1/mentions` |
| `snapshots.json` | `GET /v1/snapshots` |
| `bookmarks.json` | `GET`/`PUT /v1/bookmarks` |
| `vaults.json` | `GET /v1/vaults` |
| `session.json` | `POST /auth/session` |
| `error.json` | every error |

`GET /v1/file` and `GET /v1/snapshots/{id}/content` return the raw content, not JSON.
Only the keywords the schemas use are supported by the server test's validator
(`type`, `enum`, `pattern`, `minimum`, `required`, `properties`,
`additionalProperties`, `items`, `$ref`, `$defs`).
