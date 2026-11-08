# Obsidian YAML Properties and Tags — backend compatibility

This milestone implements the **backend** parser, persistent per-head
projection, tag browser and property search for Markdown Vaults. It does
not add an Obsidian editor, a Properties sidebar or custom property type
settings. Canvas and Bases are expressly **out of scope**.

## Source formats and data preservation

The parser uses pinned `Yams 6.2.2` to interpret an initial
`---` YAML frontmatter mapping, including quoted strings,
escaped strings, block/folded multiline strings, flow/block lists,
bools, numbers, null, ISO dates and datetime values. JSON objects
between frontmatter delimiters are also accepted. The original YAML
is **never serialized back** or rewritten during indexing.

The projection includes the name, detected type and JSON value for
each top-level property. Property types include `text`,
`number`, `checkbox`, `date`, `datetime`,
`list`, `tags`, `null` and `object`.
Nested object values are preserved as JSON for inspection, but no
Obsidian-compatible nested-property UI or equality search is promised.
Unsupported/invalid YAML is identified by `state=invalid` and a
bounded diagnostic; the note is still indexed, and no partial YAML
property projection is published.

Obsidian-style tags are extracted both from YAML `tags`
lists and from Markdown body `#tags`. Tags are Unicode-aware,
case-insensitive, may contain hierarchy segments (`work/project`),
and cannot be purely numeric or contain spaces. Duplicated appearances
have a single canonical key, with original display spelling and source
(`frontmatter` or `inline`) available in per-note detail.
The inline scanner skips fenced/inline code, escaped hashes, HTML
comments/tags and link destination URLs. A parent-tag filter matches
the parent **and** its nested descendants, but not superficially similar
prefixes (`project` does not match `projectile`).

A real Obsidian note remains a plain Markdown file. Andesite does
not write to `.obsidian/`, `.andesite/vault.json` beyond
existing path selection, or source files merely to index attributes.
The conditional full-Markdown PUT already available can edit an
existing YAML note with an exact expected revision and durable
preimage; this milestone does **not** add automatic YAML editing or
property-setting endpoints that could rewrite comments/formatting.

## Indexed database and background behavior

SQLite v9 adds `document_properties`,
`document_property_keys`, `document_property_values`
and `document_tags`. The existing search-index transaction
updates these projections alongside `document_metadata`,
FTS and the same head revision ID. Deletion/rename and a changed
revision cannot return stale tags or properties because queries
join only current live heads and reject open incidents.

An existing v8 catalog is migrated without touching original note
bytes. On the next successful reconciliation, Andesite backfills
missing properties and tags from **verified immutable revision
objects**, retaining document IDs, snapshots and historical revisions.
There is no separate metadata writer or independent SQLite connection.

## Read-only HTTP API (Hummingbird on authenticated loopback)

- `GET /v1/tags?limit=50&offset=0` — distinct canonical
  tags, first display spelling and per-tag document count
- `GET /v1/properties?limit=50&offset=0` — property
  names, observed types, type conflicts and document counts
- `GET /v1/documents/DOCUMENT_ID/properties` — exact
  indexed property JSON, typed values, tag origins and parse status
- `GET /v1/documents` — optional `tag`,
  `property`, `value` selectors, all AND-ed
- `GET /v1/search?q=phrase` — same selectors; a
  bounded subset of Obsidian search syntax inside q:
  `tag:#project`, `[priority]`,
  `[priority:5]`, optionally with a free-text phrase

Examples:

```sh
curl -G -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
  --data-urlencode 'tag=project' \
  http://127.0.0.1:8788/v1/documents

curl -G -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
  --data-urlencode 'property=priority' \
  --data-urlencode 'value=5' \
  http://127.0.0.1:8788/v1/documents

curl -G -H "Authorization: Bearer $ANDESITE_API_TOKEN" \
  --data-urlencode 'q=tag:#project [priority:5]' \
  http://127.0.0.1:8788/v1/search
```

Results are based on the last successfully completed reconciliation,
not a read of the current mutable source note. Unsafe/invalid
selectors return HTTP 400. Unavailable indexes return HTTP 503.
Read requests never modify the YAML or start a nested scan.

## Current compatibility boundaries

Obsidian's **editor** offers property type management, type coercion,
completion, property visibility, and direct property editing; those
UI workflows are still missing. Advanced Obsidian search syntax
(Boolean nesting, regex, comparisons/inequalities, mixed-property
operator semantics) is not fully implemented. YAML tags, duplicate
property names, exotic YAML tags/aliases, malformed documents, and
frontmatter exceeding 64 KiB may be rejected or marked invalid
rather than silently indexed incorrectly. Automatic tag rename across
a Vault, editable tag pane, and unlinked mention detection are not
implemented.

This is a verified **backend subset**, not a claim of full Obsidian
application parity. Canvas and Bases have intentionally not been
added.

## Regression verification

`ObsidianMetadataTests.swift` checks typed YAML, flow/JSON
frontmatter, Unicode/emoji/nested tags, excluded code and invalid
YAML. `ObsidianMetadataIndexTests.swift` checks live
revision selection, property/tag AND filters, rename/edit invalidation,
v8->v9 backfill from immutable bytes and HTTP guards.
`ObsidianSearchQueryTests.swift` checks supported operator
syntax and refusal of unsupported comparisons.
`scripts/test-api-server.sh` exercises authentication,
pagination/filtering, tag browsing and mutation invalidation over
real Hummingbird+FSEvents processes in a disposable Vault.

Run `swift test`, `scripts/test-api-server.sh`
and `swift build -c release`. The compatibility register
`docs/obsidian-compatibility.md` must be kept up to date
with actual tested behavior.

Reference: Obsidian official help:
https://help.obsidian.md/properties ,
https://help.obsidian.md/tags and
https://help.obsidian.md/plugins/search .
