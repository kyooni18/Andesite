# Obsidian compatibility and feature-gap register

**Baseline checked:** 2026-11-08, against official Obsidian Help.
**Conclusion:** Andesite is not feature-equivalent to Obsidian. It is
currently a Swift 6 macOS file-observation, recovery and read-only HTTP
backend, not a replacement Markdown editor. Never claim overall parity
until the same observable behavior has been verified side by side.

## Official reference contracts

- Vault data and configuration: https://obsidian.md/help/data-storage
- Core plugins: https://obsidian.md/help/plugins
- Links and automatic link updates: https://obsidian.md/help/links
- Properties / typed YAML: https://obsidian.md/help/properties
- Bases: https://obsidian.md/help/bases
- Canvas: https://obsidian.md/help/plugins/canvas
- Accepted formats: https://obsidian.md/help/file-formats
- Config-folder overrides: https://obsidian.md/help/configuration-folder
- File management, trash and excluded files: https://obsidian.md/help/settings

## Current compatibility matrix

**Implemented** means a specific narrow behavior works and is regression
tested. **Partial** means an important subset is missing. **Missing**
means no equivalent. Backend data compatibility is not desktop UI parity.

| Obsidian capability | Andesite status | Evidence and gaps |
| --- | --- | --- |
| Plain Markdown in a Vault | **Implemented (observation)** | VaultReader, DocumentCatalogTests; no content rewriting during indexing |
| Vault open/close and moves | **Partial** | VaultSessionTests: same-volume moves retain IDs; cross-volume verified migration absent |
| Default .obsidian configuration | **Partial** | DocumentCatalogTests: skip and preserve settings; overridden config folder names not discovered |
| .trash and .git root directories | **Partial** | DocumentCatalogTests: skip as note sources, no UI trash controls |
| Notes list / folder browsing | **Partial** | Paginated GET /v1/documents; flat paths, no full file explorer |
| Document content / outline | **Partial** | Exact immutable current heads; CommonMark headings bounded to 256 KiB and 256 items; no editable live preview |
| Standard Markdown links | **Partial** | AST destinations in document detail; unresolved targets |
| Wikilinks / embeds / aliases / heading references | **Partial** | ObsidianLinks extracts raw syntax outside code; no destination/anchor resolution |
| Backlinks and unlinked mentions | **Missing** | No full link graph or reverse references |
| Graph view | **Missing** | No visual graph |
| Frontmatter YAML / Properties | **Missing** | Raw bytes retained, no typed property index or UI |
| Bases (.base) | **Missing** | No Bases format parser/views/formulas |
| Canvas (.canvas) | **Missing** | No JSON Canvas cards/edges renderer |
| Media / PDF attachments and embeds | **Missing** | Files are preserved, not navigable/viewable via note API |
| Content search | **Partial** | SQLite FTS phrase search returns Vault-relative path; Obsidian search operators, property/tag filters and snippets absent |
| Tags, outgoing links panel, outline UI | **Partial** | Raw headings/link syntax only; no tag index or app panel |
| File recovery | **Partial** | SHA-256 immutable revisions, snapshots and APFS restore; settings and UX not identical |
| Create, edit, rename, delete by API | **Missing** | Current HTTP intentionally GET-only; journal-safe mutation API pending |
| Daily notes, templates, bookmarks, quick switcher | **Missing** | No matching app-level workflows |
| Page preview, command palette, workspaces | **Missing** | No editor UI |
| Plugins, themes, CSS snippets | **Missing** | No user extension runtime |
| Web Clipper, URI hooks, slides, audio recorder | **Missing** | No corresponding app integrations |
| Sync and Publish | **Missing** | No remote authenticated synchronization/publication |
| Cross-platform desktop/mobile | **Missing** | macOS-first backend; Hummingbird HTTP macOS 14+ |

Full feature parity is **not achieved**. Andesite's strongest distinctive
area is recovery integrity, not Obsidian's linked knowledge UI.

## Rerunnable verification evidence

- `DocumentCatalogTests.swift`: paginated live heads, stable IDs,
  immutable current content, rename/deletion history, default .obsidian,
  .trash and .git preservation, lexical Obsidian wiki syntax.
- `VaultLocalHTTPTests.swift`: read-only document routes, page guards,
  stale-index refusal, exact immutable bytes, partial heading/link extraction.
- `scripts/test-api-server.sh`: Hummingbird and FSEvents against
  temporary Vaults, auth, live GETs, and HTTP method rejection.
- Existing VaultSessionTests, RecoverySnapshotTests, VaultMonitorTests and
  journal/SIGKILL tests protect persistence and single-owner guarantees.

## Verify again at each later milestone

1. Check the relevant official Obsidian Help page and create a reproduction
   fixture for the exact claimed behavior, not a vague similarity judgment.
2. Separate **syntax recognition** from link resolution, and file preservation
   from render/edit support; mark Partial until the real behavior works.
3. Include Unicode, aliases, escaped link syntax, block references, ambiguous
   paths, external moves and stale-head data in compatibility tests.
4. Run `swift test`, `scripts/test-api-server.sh`, and
   Release smoke before claiming a shipped milestone; preserve user note
   bytes and their existing default Obsidian configuration.
5. Update this matrix in the same commit as new features.

**Next priority:** Obsidian-correct link target resolution/backlinks and
renames; typed frontmatter/Properties and search filters; attachment and
Canvas/Bases indexing; journal-safe write APIs; editor and plugin parity.
