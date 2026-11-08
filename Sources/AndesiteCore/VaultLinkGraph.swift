import Foundation

public enum VaultLinkGraphError: Error, Equatable {
    case invalidQuery
    case graphTooLarge
    case inconsistentCatalog
    case cacheNotReady
}

public enum VaultLinkDirection: Sendable {
    case outgoing
    case incoming
}

/// One lexical mention plus its conservative resolution against the current
/// immutable catalog. A resolved file may still have a missing/unsupported
/// fragment; never interpret that as an existing target heading/block.
public struct VaultLinkMention: Sendable {
    public let sourceID: Data
    public let sourcePath: String
    public let syntax: String
    public let target: String
    public let fragment: String?
    public let display: String?
    public let embed: Bool
    public let status: String
    public let documentID: Data?
    public let documentPath: String?
    public let fragmentStatus: String
    public let aliasSuggestions: [String]
}

public struct VaultLinkPage: Sendable {
    public let mentions: [VaultLinkMention]
    public let total: Int
    public let offset: Int
    public var nextOffset: Int? {
        offset + mentions.count < total ? offset + mentions.count : nil
    }
}

/// Transient read-only link graph built from verified immutable current heads.
/// The graph is deliberately bounded instead of returning quietly incomplete
/// backlinks on large/unindexable vaults. No extra SQLite connection, DB
/// migration, or source-file access is required.
public enum VaultLinkGraph {
    private static let maximumDocuments = 2_000
    private static let maximumDocumentBytes = 256 * 1024
    private static let maximumTotalBytes = 24 * 1024 * 1024
    private static let maximumMentions = 20_000
    private static let maximumPerDocumentMentions = 512

    fileprivate struct RawReference {
        let syntax: String
        let target: String
        let fragment: String?
        let display: String?
        let embed: Bool
    }

    fileprivate struct Node {
        let document: IndexedDocument
        let references: [RawReference]
        let headings: [String]
        let blocks: [String]
        let aliases: [String]
    }

    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func baseName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        if last.lowercased().hasSuffix(".md") { return String(last.dropLast(3)) }
        return last
    }

    private static func pathKey(_ value: String) -> String {
        let stripped = value.lowercased().hasSuffix(".md") ?
            String(value.dropLast(3)) : value
        return key(stripped)
    }

    private static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
           (trimmed.first == "\"" && trimmed.last == "\"" ||
            trimmed.first == "'" && trimmed.last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Restricted extraction of the well-defined Obsidian aliases YAML list.
    /// This is NOT a full YAML parser, and alias-only target names never
    /// silently resolve to the aliased document. Obsidian uses aliases for
    /// link suggestions and writes canonical targets with display labels.
    private static func aliases(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [] }
        var values: [String] = []
        var insideAliases = false
        var foundEnd = false
        for line in lines.dropFirst().prefix(200) {
            if line == "---" || line == "..." { foundEnd = true; break }
            if line.hasPrefix("aliases:") {
                insideAliases = true
                let rest = String(line.dropFirst("aliases:".count)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("["), rest.hasSuffix("]") {
                    let inner = rest.dropFirst().dropLast()
                    values += inner.split(separator: ",").map { unquote(String($0)) }
                    insideAliases = false
                } else if !rest.isEmpty {
                    // Only list syntax is compatible with current Obsidian.
                    insideAliases = false
                }
                continue
            }
            if insideAliases {
                if line.hasPrefix("  - ") || line.hasPrefix("- ") {
                    let token = line.hasPrefix("  - ") ?
                        String(line.dropFirst(4)) : String(line.dropFirst(2))
                    values.append(unquote(token))
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    insideAliases = false
                }
            }
        }
        guard foundEnd else { return [] }
        return Array(Set(values.filter { !$0.isEmpty && $0.utf8.count <= 256 })).sorted()
    }

    private static func blockIDs(_ text: String) -> [String] {
        // Only explicit Latin-letter/digit/hyphen block identifiers. Do not
        // extract from fenced or indented CommonMark code. Other nonstandard
        // block markup is intentionally not asserted as resolved.
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)\\^([A-Za-z0-9-]+)\\s*$") else {
            return []
        }
        var identifiers: [String] = []
        var fence: (Character, Int)?
        for line in text.components(separatedBy: .newlines) {
            let leading = line.prefix(while: { $0 == " " }).count
            let body = leading <= 3 ? String(line.dropFirst(leading)) : line
            if let open = fence {
                let closing = body.prefix(while: { $0 == open.0 }).count
                if body.first == open.0 && closing >= open.1 &&
                   body.dropFirst(closing).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                continue
            }
            if leading >= 4 { continue }
            let prefix = body.prefix(while: { $0 == "`" || $0 == "~" })
            if prefix.count >= 3, let character = prefix.first {
                fence = (character, prefix.count)
                continue
            }
            let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: searchRange),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            identifiers.append(String(line[range]))
        }
        return identifiers
    }

    /// Snapshot published atomically on the Vault's single owner thread.
    /// Repeated HTTP requests only page arrays in memory, never scan notes.
    struct Snapshot {
        fileprivate let nodes: [Node]
        fileprivate let documentIDs: Set<Data>
        fileprivate let outgoing: [Data: [VaultLinkMention]]
        fileprivate let incoming: [Data: [VaultLinkMention]]

        func query(documentID: Data, direction: VaultLinkDirection,
                   limit: Int, offset: Int) throws -> VaultLinkPage {
            guard documentID.count == 16, (1...100).contains(limit),
                  (0...100_000).contains(offset) else {
                throw VaultLinkGraphError.invalidQuery
            }
            guard documentIDs.contains(documentID) else {
                throw DocumentCatalogError.notFound
            }
            let result: [VaultLinkMention]
            switch direction {
            case .outgoing: result = outgoing[documentID] ?? []
            case .incoming: result = incoming[documentID] ?? []
            }
            return VaultLinkPage(mentions: Array(result.dropFirst(offset).prefix(limit)),
                                 total: result.count, offset: offset)
        }
    }

    struct BuildResult {
        let snapshot: Snapshot
        let parsed: Int
        let reused: Int
        let changed: Bool
    }

    private static func documents(db: SQLiteConnection, vaultID: Data) throws -> [IndexedDocument] {
        let initial = try DocumentCatalog.list(db: db, vaultID: vaultID, limit: 100)
        guard initial.total <= maximumDocuments else { throw VaultLinkGraphError.graphTooLarge }
        var documents = initial.documents
        while documents.count < initial.total {
            let next = try DocumentCatalog.list(db: db, vaultID: vaultID,
                                                limit: 100, offset: documents.count)
            guard !next.documents.isEmpty, next.total == initial.total else {
                throw VaultLinkGraphError.inconsistentCatalog
            }
            documents.append(contentsOf: next.documents)
        }
        return documents
    }

    /// A low-priority scheduled operation, never called from an HTTP handler.
    /// Reuses parsed syntax from unchanged revision IDs; when namespace names
    /// move, all in-memory references are re-resolved without rereading notes.
    static func prepare(db: SQLiteConnection, objects: ObjectStore,
                        vaultID: Data, previous: Snapshot?) throws -> BuildResult {
        let current = try documents(db: db, vaultID: vaultID)
        if let previous, previous.nodes.count == current.count,
           zip(previous.nodes, current).allSatisfy({ old, new in
               old.document.id == new.id &&
               old.document.revisionID == new.revisionID &&
               old.document.path == new.path &&
               old.document.hash == new.hash &&
               old.document.byteLength == new.byteLength
           }) {
            return BuildResult(snapshot: previous, parsed: 0,
                               reused: current.count, changed: false)
        }

        let oldNodes = Dictionary(uniqueKeysWithValues: (previous?.nodes ?? []).map {
            ($0.document.id, $0)
        })
        var nodes: [Node] = []
        var totalBytes = 0
        var totalReferences = 0
        var parsed = 0
        var reused = 0

        for document in current {
            guard document.byteLength <= maximumDocumentBytes,
                  totalBytes + document.byteLength <= maximumTotalBytes else {
                throw VaultLinkGraphError.graphTooLarge
            }
            let node: Node
            if let cached = oldNodes[document.id],
               cached.document.revisionID == document.revisionID &&
               cached.document.hash == document.hash &&
               cached.document.byteLength == document.byteLength {
                node = Node(document: document, references: cached.references,
                            headings: cached.headings, blocks: cached.blocks,
                            aliases: cached.aliases)
                reused += 1
            } else {
                let bytes = try DocumentCatalog.content(objects: objects, document: document,
                                                        maximumBytes: maximumDocumentBytes)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw VaultLinkGraphError.inconsistentCatalog
                }
                let facts = try MarkdownAnalyzer.analyze(bytes)
                var refs = ObsidianLinks.extract(text).map {
                    RawReference(syntax: "wikilink", target: $0.target,
                                 fragment: $0.fragment, display: $0.alias, embed: $0.embed)
                }
                for destination in facts.linkDestinations {
                    let parts = destination.split(separator: "#", maxSplits: 1,
                                                  omittingEmptySubsequences: false)
                    refs.append(RawReference(syntax: "markdown", target: String(parts[0]),
                                             fragment: parts.count == 2 ? String(parts[1]) : nil,
                                             display: nil, embed: false))
                }
                node = Node(document: document, references: refs,
                            headings: facts.headings.map(\.text),
                            blocks: blockIDs(text), aliases: aliases(text))
                parsed += 1
            }
            guard node.references.count <= maximumPerDocumentMentions,
                  totalReferences + node.references.count <= maximumMentions else {
                throw VaultLinkGraphError.graphTooLarge
            }
            totalBytes += document.byteLength
            totalReferences += node.references.count
            nodes.append(node)
        }

        var byPath: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]
        var byAlias: [String: [Int]] = [:]
        for index in nodes.indices {
            let node = nodes[index]
            byPath[pathKey(node.document.path), default: []].append(index)
            byName[key(baseName(node.document.path)), default: []].append(index)
            for alias in node.aliases {
                byAlias[key(alias), default: []].append(index)
            }
        }

        var outgoing: [Data: [VaultLinkMention]] = [:]
        var incoming: [Data: [VaultLinkMention]] = [:]
        for node in nodes {
            var mentions: [VaultLinkMention] = []
            for link in node.references {
                let mention = resolve(link, source: node, nodes: nodes,
                                      byPath: byPath, byName: byName, byAlias: byAlias)
                mentions.append(mention)
                if let targetID = mention.documentID {
                    incoming[targetID, default: []].append(mention)
                }
            }
            outgoing[node.document.id] = mentions
        }
        return BuildResult(snapshot: Snapshot(nodes: nodes,
                                               documentIDs: Set(nodes.map { $0.document.id }),
                                               outgoing: outgoing, incoming: incoming),
                           parsed: parsed, reused: reused, changed: true)
    }

    private static func fragmentStatus(_ fragment: String?, on node: Node) -> String {
        guard let fragment else { return "none" }
        guard !fragment.isEmpty else { return "invalid" }
        if fragment.hasPrefix("^") {
            let identifier = String(fragment.dropFirst())
            guard !identifier.isEmpty && identifier.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45
            }) else { return "unsupported" }
            let count = node.blocks.filter { $0 == identifier }.count
            return count == 1 ? "resolved" : (count == 0 ? "missing" : "ambiguous")
        }
        if fragment.contains("#") { return "unsupported" }
        let count = node.headings.filter { key($0) == key(fragment) }.count
        return count == 1 ? "resolved" : (count == 0 ? "missing" : "ambiguous")
    }

    private static func resolve(_ link: RawReference, source: Node, nodes: [Node],
                                byPath: [String: [Int]], byName: [String: [Int]],
                                byAlias: [String: [Int]]) -> VaultLinkMention {
        var target = link.target
        var fragment = link.fragment
        let original = link.target
        // Obsidian uses special global heading/block search tokens. These
        // are suggestions, not links to the current note or a file named
        // after the query.
        if link.syntax == "wikilink" &&
           ((target.isEmpty && (fragment?.hasPrefix("#") == true)) ||
            target.hasPrefix("^^")) {
            return mention(link, source: source, status: "unsupported")
        }
        var status = "missing"
        var matches: [Int] = []
        if link.syntax == "markdown" {
            guard let decoded = target.removingPercentEncoding else {
                return mention(link, source: source, status: "unsupported")
            }
            if let encoded = fragment {
                guard let decodedFragment = encoded.removingPercentEncoding else {
                    return mention(link, source: source, status: "unsupported")
                }
                fragment = decodedFragment
            }
            target = decoded
        }
        // Only local note links are resolved. Known schemes / non-Markdown
        // assets are reported rather than linked to some similar note.
        let lower = target.lowercased()
        let scheme = target.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:",
                                  options: .regularExpression) != nil
        if scheme || target.hasPrefix("//") {
            return mention(link, source: source, status: "external")
        }
        if [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp",
            ".pdf", ".mp3", ".mp4", ".mov", ".canvas", ".base"].contains(where: lower.hasSuffix) {
            return mention(link, source: source, status: "unsupported")
        }
        if target.isEmpty {
            if fragment == nil || fragment == "" {
                return mention(link, source: source, status: "unsupported")
            }
            matches = nodes.indices.filter { nodes[$0].document.id == source.document.id }
        } else {
            guard !target.hasPrefix("/"), !target.contains("\\"),
                  !target.contains("//"), target.utf8.count <= 1024,
                  !target.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control
                  }) else {
                return mention(link, source: source, status: "unsupported")
            }
            if target.hasPrefix("./") || target.hasPrefix("../") {
                // Explicit Markdown relative paths are relative to the source
                // note's parent. Never walk beyond the Vault root.
                guard link.syntax == "markdown" else {
                    return mention(link, source: source, status: "unsupported")
                }
                var parent = source.document.path.split(separator: "/").dropLast().map(String.init)
                for part in target.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." {
                        guard !parent.isEmpty else {
                            return mention(link, source: source, status: "unsupported")
                        }
                        parent.removeLast()
                    } else {
                        parent.append(String(part))
                    }
                }
                matches = byPath[pathKey(parent.joined(separator: "/"))] ?? []
            } else if target.contains("/") {
                guard !target.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
                    return mention(link, source: source, status: "unsupported")
                }
                matches = byPath[pathKey(target)] ?? []
            } else {
                matches = byName[pathKey(target)] ?? []
            }
        }

        if matches.count > 1 {
            status = "ambiguous"
        } else if matches.count == 1 {
            status = "resolved"
        }
        let found = matches.count == 1 ? nodes[matches[0]] : nil
        let aliasIDs = byAlias[key(original)] ?? []
        let suggestions = found == nil ?
            aliasIDs.prefix(8).map { nodes[$0].document.path }.sorted() : []
        return VaultLinkMention(
            sourceID: source.document.id, sourcePath: source.document.path,
            syntax: link.syntax, target: original, fragment: fragment,
            display: link.display, embed: link.embed, status: status,
            documentID: found?.document.id, documentPath: found?.document.path,
            fragmentStatus: found.map { fragmentStatus(fragment, on: $0) } ?? "unresolved",
            aliasSuggestions: suggestions
        )
    }

    private static func mention(_ link: RawReference, source: Node,
                                status: String) -> VaultLinkMention {
        VaultLinkMention(sourceID: source.document.id, sourcePath: source.document.path,
                         syntax: link.syntax, target: link.target,
                         fragment: link.fragment, display: link.display,
                         embed: link.embed, status: status,
                         documentID: nil, documentPath: nil,
                         fragmentStatus: "unresolved", aliasSuggestions: [])
    }

}
