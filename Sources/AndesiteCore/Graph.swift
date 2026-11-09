import Foundation

/// A read-only snapshot of how the vault's files link to each other, made
/// from the link index and resolved with the same rules as `links`.
///
/// ```swift
/// let graph = try await vault.graph()
/// for edge in graph.edges { print(edge.source, "→", edge.target, edge.count) }
/// ```
///
/// Nodes are every live note, plus each attachment some note links to.
/// They are identified by document ID, which survives renames. An edge is
/// one or more resolved links from one file to another (embeds included,
/// links to the note itself not). Links that point at no file, or at
/// several equally good ones, are not edges; they are listed in `unresolved`.
public struct VaultGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public let id: Data
        public let path: String
        /// "markdown" or "attachment".
        public let kind: String
        /// Canonical tags of the note's indexed revision (property and inline).
        public let tags: [String]

        /// The file name, without ".md" for notes.
        public var name: String {
            let file = path.split(separator: "/").last.map(String.init) ?? path
            return kind == "markdown" ? LinkIndex.withoutMarkdownExtension(file) : file
        }

        /// The containing folder, "" at the vault root.
        public var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    }

    public struct Edge: Sendable, Equatable, Hashable {
        public let source: Data
        public let target: Data
        /// How many links from `source` resolve to `target`.
        public let count: Int
    }

    /// A link whose target is "missing" or "ambiguous".
    public struct UnresolvedLink: Sendable, Equatable {
        public let source: Data
        public let target: String
        public let status: String
    }

    public let nodes: [Node]
    public let edges: [Edge]
    public let unresolved: [UnresolvedLink]
}

/// A live file as the graph needs it.
struct GraphFile: Sendable {
    let file: LinkedFile
    let pathKey: String
    let nameKey: String
}

/// The catalog's live files in memory, answering resolution lookups
/// exactly like `CatalogLinkLookup`.
struct GraphFileIndex: LinkTargetLookup {
    private var byID: [Data: LinkedFile] = [:]
    private var byPathKey: [String: LinkedFile] = [:]
    private var byName: [String: [LinkedFile]] = [:]

    init(_ files: [GraphFile]) {
        for item in files {
            byID[item.file.id] = item.file
            byPathKey[item.pathKey] = item.file
            byName[item.nameKey, default: []].append(item.file)
        }
    }

    func kind(of id: Data) -> String? { byID[id]?.kind }

    func live(path: String) -> LinkedFile? {
        (try? VaultPath(path).portabilityKey).flatMap { byPathKey[$0] }
    }

    func named(_ key: String) -> [LinkedFile] { byName[key] ?? [] }
}

extension VaultGraph {
    /// Resolves every link against `files`. Pure, so it runs off the
    /// vault's thread. Resolution depends only on a link's syntax, its
    /// target and the source's folder, so repeated targets resolve once.
    static func build(files: [GraphFile], tags: [Data: [String]], links: [StoredLink]) throws -> VaultGraph {
        let index = GraphFileIndex(files)
        var cache: [String: (String, LinkedFile?)] = [:]
        var counts: [Data: [Data: Int]] = [:]
        var unresolved: [UnresolvedLink] = []
        var linkedAttachments = Set<Data>()
        for (offset, link) in links.enumerated() {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            guard index.kind(of: link.sourceID) != nil, !link.target.isEmpty else { continue }
            let folder = link.sourcePath.split(separator: "/").dropLast().joined(separator: "/")
            let key = link.syntax + "\u{0}" + folder + "\u{0}" + link.target
            let resolution: (String, LinkedFile?)
            if let cached = cache[key] {
                resolution = cached
            } else {
                resolution = try VaultRuntime.resolve(syntax: link.syntax, target: link.target, from: link.sourcePath,
                                                      sourceID: link.sourceID, in: index)
                cache[key] = resolution
            }
            switch resolution {
            case ("resolved", let file?) where file.id != link.sourceID:
                counts[link.sourceID, default: [:]][file.id, default: 0] += 1
                if file.kind != "markdown" { linkedAttachments.insert(file.id) }
            case ("missing", _), ("ambiguous", _):
                unresolved.append(UnresolvedLink(source: link.sourceID, target: link.target, status: resolution.0))
            default:
                continue
            }
        }
        let nodes = files.filter { $0.file.kind == "markdown" || linkedAttachments.contains($0.file.id) }
            .sorted { $0.file.path < $1.file.path }
            .map { Node(id: $0.file.id, path: $0.file.path, kind: $0.file.kind, tags: tags[$0.file.id] ?? []) }
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let edges = counts.flatMap { source, targets in
            targets.map { Edge(source: source, target: $0.key, count: $0.value) }
        }.sorted { (order[$0.source]!, order[$0.target]!) < (order[$1.source]!, order[$1.target]!) }
        return VaultGraph(nodes: nodes, edges: edges, unresolved: unresolved)
    }
}

extension VaultRuntime {
    /// Every live file, with the tags of each note's indexed revision.
    func graphFiles() throws -> (files: [GraphFile], tags: [Data: [String]]) {
        let r = try requireReady()
        let files = try r.db.queryValues("SELECT id,path,kind,path_key,name_key FROM entries WHERE vault_id=? AND state='live'",
                                         bindings: [.blob(vaultID)]).map { row -> GraphFile in
            guard case .blob(let id) = row[0], case .text(let path) = row[1], case .text(let kind) = row[2],
                  case .text(let pathKey) = row[3] else { throw VaultRuntimeError.inconsistentCatalog }
            var nameKey = LinkIndex.nameKey(path)
            if case .text(let stored) = row[4] { nameKey = stored }
            return GraphFile(file: LinkedFile(id: id, path: path, kind: kind), pathKey: pathKey, nameKey: nameKey)
        }
        var tags: [Data: [String]] = [:]
        for row in try r.db.queryValues("""
            SELECT DISTINCT t.entry_id,t.canonical FROM document_tags t
            JOIN entries e ON e.vault_id=t.vault_id AND e.id=t.entry_id AND e.head_revision=t.indexed_revision AND e.state='live'
            WHERE t.vault_id=? ORDER BY t.entry_id,t.canonical
            """, bindings: [.blob(vaultID)]) {
            guard case .blob(let id) = row[0], case .text(let tag) = row[1] else { throw VaultRuntimeError.inconsistentCatalog }
            tags[id, default: []].append(tag)
        }
        return (files, tags)
    }

    /// Up to `limit` links of current note revisions, in key order after
    /// `cursor` (a source ID and link ordinal), so a large index is read in
    /// short steps that let other requests in between.
    func graphLinks(after cursor: (source: Data, ordinal: Int)?, limit: Int) throws -> [StoredLink] {
        let r = try requireReady()
        var bindings: [SQLiteValue] = [.blob(vaultID)]
        var condition = ""
        if let cursor {
            condition = " AND (l.entry_id>? OR (l.entry_id=? AND l.ordinal>?))"
            bindings += [.blob(cursor.source), .blob(cursor.source), .integer(Int64(cursor.ordinal))]
        }
        return try r.db.queryValues("""
            SELECT \(Self.storedLinkColumns)
            FROM document_links l JOIN entries e ON e.vault_id=l.vault_id AND e.id=l.entry_id
              AND e.head_revision=l.revision_id AND e.state='live'
            WHERE l.vault_id=?\(condition) ORDER BY l.entry_id,l.ordinal LIMIT ?
            """, bindings: bindings + [.integer(Int64(limit))]).map(Self.storedLink)
    }

    /// The whole graph in one call on this thread (see `Vault.graph()`,
    /// which reads in steps and resolves off the vault's thread).
    func graph() throws -> VaultGraph {
        let (files, tags) = try graphFiles()
        var links: [StoredLink] = []
        while true {
            let page = try graphLinks(after: links.last.map { ($0.sourceID, $0.ordinal) }, limit: Vault.graphPageSize)
            links += page
            if page.count < Vault.graphPageSize { break }
        }
        return try VaultGraph.build(files: files, tags: tags, links: links)
    }
}

extension Vault {
    static let graphPageSize = 4096

    /// A snapshot of the vault's link graph (see `VaultGraph`). The index is
    /// read in short steps, so edits and other reads are not held up, and
    /// links are resolved off the vault's thread. Throws
    /// `VaultRuntimeError.indexNotReady` until the first scan ends.
    @concurrent
    public func graph() async throws -> VaultGraph {
        let (files, tags) = try await perform(.read) { try $0.graphFiles() }
        var links: [StoredLink] = []
        while true {
            try Task.checkCancellation()
            let cursor = links.last.map { ($0.sourceID, $0.ordinal) }
            let page = try await perform(.read) { try $0.graphLinks(after: cursor, limit: Self.graphPageSize) }
            links += page
            if page.count < Self.graphPageSize { break }
        }
        return try VaultGraph.build(files: files, tags: tags, links: links)
    }
}
