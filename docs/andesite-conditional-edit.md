# Journal-backed conditional Markdown editing

Andesite can update an **existing live Markdown note** through either the
same-owner Swift API, the local CLI or the authenticated loopback HTTP
server. This milestone does not implement file creation, deletion,
folder rename, conflict-free collaboration, or Obsidian's editor UI.

## Foreground update contract

The caller first GETs the document metadata and receives a stable
document ID and its exact 16-byte revision as 32 lowercase hexadecimal
characters. It then submits the new full Markdown bytes (not a patch)
with an exact expected head:

PUT /v1/documents/DOCUMENT_ID/content
Authorization: Bearer 64-HEX-TOKEN
If-Match: "EXPECTED_REVISION_HEX"
Content-Type: text/markdown; charset=utf-8
Content-Length: (actual byte count)

Accepted body size: 0 through 262144 bytes. No wildcard If-Match, no
upsert, no symlink/path selection from the HTTP request, no arbitrary
file path, and no implicit "last writer wins." Successful responses
include operation, document, new revision, preimage snapshot ID,
completion state, and indexReady=false.

The first foreground operation checks: same-user authenticated sidecar,
exact live document/revision, secure physical APFS path, source inode
and content hash equal to the indexed revision, valid UTF-8 Markdown,
and the durable journal's mutation state. A stale head or racing external
editor is rejected without overwriting their bytes.

For a successful edit, the original revision/preimage and intended
replacement each have immutable SHA-256 objects on durable storage.
The existing mutation journal records their ownership, parent revision,
new revision ID, expected filesystem identities, and exchange artifact.
A private staged inode is fully synchronized, then exchanged with the
original using the previously qualified APFS atomic exchange mechanism.
The displaced original inode remains retained as an auditable artifact.
The catalog/FTS update is journaled; an interrupted process is reconciled
on restart, never blindly exchanged a second time.

Only after the file exchange and journal completion does this endpoint
report HTTP 200. The response reports indexReady=false because the
watcher's scheduler must still run its FSEvents/namespace reconciliation
and update the disposable link cache. This operation does not synchronously
rebuild backlinks. During that interval stale indexed GETs fail closed.

## Example

Run the Vault watch process and Hummingbird loopback API as documented
in andesite-http-server.md, using the same bearer token:

    curl -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
      http://127.0.0.1:8788/v1/documents

Use the returned document and revision IDs:

    curl -X PUT \
      -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
      -H 'If-Match: "EXPECTED_REVISION_HEX"' \
      -H 'Content-Type: text/markdown; charset=utf-8' \
      --data-binary @updated-note.md \
      http://127.0.0.1:8788/v1/documents/DOCUMENT_ID/content

The single-owner CLI is available **only when the watch process is not
holding that same state lock**:

    cat updated-note.md | andesite-server document-edit \
      --vault /absolute/vault --state /absolute/private-state \
      DOCUMENT_ID EXPECTED_REVISION_HEX --stdin

The CLI also enforces the 256-KiB bound and uses the exact same
journaled core operation.

## Refusal and recovery contract

- 401: no/mismatched bearer token
- 400: invalid framing, type or body length
- 405: other modifying verbs; creation/deletion remain unsupported
- 409: raced external file change, journal conflict or unsafe target
- 412: indexed document head does not match If-Match
- 413: oversized HTTP upload
- 422: invalid UTF-8 Markdown
- 428: missing/invalid explicit revision precondition
- 503: pending scan or unavailable backend

These are the local server responses, not a remotely authenticated
public API contract. A repeated request after success can receive
503 while indexing catches up, followed by 412 when the newer revision
is ready; it cannot publish twice using the stale expected revision.
Recovery on SIGKILL from staged, exchanged, published and catalogued
states uses the journal's original evidence and replacement immutable
object. A conflict keeps all evidence for explicit inspection. The
existing mutation-inspect, mutation-export and mutation-resolve commands
now distinguish the exact intended replacement from its preimage.

The API does not yet use idempotency keys across independent clients.
Also, exclusive filesystem locks cannot prohibit writes through file
descriptors held by unrelated editors. The journal fails closed when
those changes are observed, preserving both versions for operator review.

## Regression checks

- DocumentEditJournalTests: exact precondition, valid UTF-8, conflict,
  stable document identity, new revision, original snapshot preservation,
  SIGKILL/resume and quarantine inspection/export/resolution
- VaultLocalHTTPTests: zero/malformed/wrong If-Match, unsupported method
  and content type, invalid UTF-8, pending scan, and successful update
- scripts/test-api-server.sh: real Hummingbird with authenticated PUT,
  refusal of unauthorized/stale requests, FSEvents reconciliation, search
  visibility and original snapshot preservation

All tests must operate on temporary Vaults. Existing user Vaults are
never edited for qualification without explicit identification.
