import Foundation

public enum VaultLinkDirection: Sendable {
    case outgoing
    case incoming
}

/// One link and what it currently points at.
public struct VaultLinkMention: Sendable {
    public let sourceID: Data
    public let sourcePath: String
    /// "wikilink" or "markdown".
    public let syntax: String
    public let target: String
    public let fragment: String?
    public let display: String?
    public let embed: Bool
    /// "resolved", "missing", "ambiguous", "external" or "unsupported".
    public let status: String
    public let documentID: Data?
    public let documentPath: String?
    /// "none", "resolved", "missing", "ambiguous", "invalid", "unsupported" or "unresolved".
    public let fragmentStatus: String
}

public struct VaultLinkPage: Sendable {
    public let mentions: [VaultLinkMention]
    public let total: Int
    public let offset: Int
    public var nextOffset: Int? { offset + mentions.count < total ? offset + mentions.count : nil }
}

/// A note that mentions a document's name or alias as plain text.
public struct UnlinkedMention: Sendable, Equatable {
    public let sourceID: Data
    public let sourcePath: String
    public let term: String
}

/// Links are stored per note when the note is indexed (with the byte
/// positions of their targets) and resolved against the live catalog when
/// queried, so they are always consistent with the current set of files.
enum LinkIndex {
    /// Case- and normalization-insensitive form used to match names.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func withoutMarkdownExtension(_ path: String) -> String {
        path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
    }

    /// The name a file is linked by: its last path component, without ".md".
    static func nameKey(_ path: String) -> String {
        fold(withoutMarkdownExtension(path.split(separator: "/").last.map(String.init) ?? path))
    }

    /// Replaces a note's links and anchors. Caller owns the transaction.
    static func store(db: SQLiteConnection, vaultID: Data, entryID: Data, revisionID: Data,
                      links: [ObsidianLink], anchors: [(kind: String, key: String)]) throws {
        for table in ["document_links", "document_anchors"] {
            try db.executeValues("DELETE FROM \(table) WHERE vault_id=? AND entry_id=?", bindings: [.blob(vaultID), .blob(entryID)])
        }
        for (ordinal, link) in links.enumerated() {
            let decoded = link.syntax == "markdown" ? (link.target.removingPercentEncoding ?? link.target) : link.target
            try db.executeValues("""
                INSERT INTO document_links(vault_id,entry_id,revision_id,ordinal,syntax,target,fragment,display,embed,name_key,start,end)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID), .integer(Int64(ordinal)), .text(link.syntax),
                                .text(link.target), link.fragment.map(SQLiteValue.text) ?? .null,
                                link.display.map(SQLiteValue.text) ?? .null, .integer(link.embed ? 1 : 0),
                                .text(decoded.isEmpty ? "" : nameKey(decoded)),
                                .integer(Int64(link.targetRange.lowerBound)), .integer(Int64(link.targetRange.upperBound))])
        }
        for (ordinal, (kind, key)) in anchors.enumerated() {
            try db.executeValues("INSERT INTO document_anchors(vault_id,entry_id,revision_id,ordinal,kind,key) VALUES(?,?,?,?,?,?)",
                                 bindings: [.blob(vaultID), .blob(entryID), .blob(revisionID), .integer(Int64(ordinal)), .text(kind), .text(key)])
        }
    }

    /// Block identifiers (`text ^block-id` at the end of a line), outside code.
    static func blockIDs(_ text: String) -> [String] {
        var result: [String] = [], fence: Character?
        for line in text.lines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = fence == nil ? trimmed.first : (trimmed.first == fence ? nil : fence)
                continue
            }
            guard fence == nil, !line.hasPrefix("    "), !line.hasPrefix("\t"),
                  let caret = trimmed.range(of: "^", options: .backwards) else { continue }
            let id = trimmed[caret.upperBound...]
            let before = trimmed[..<caret.lowerBound]
            if !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
               before.isEmpty || before.last == " " || before.last == "\t" { result.append(String(id)) }
        }
        return result
    }
}

/// A live file a link can point at.
struct LinkedFile: Equatable {
    let id: Data
    let path: String
    let kind: String
}

/// A stored link of a current note revision.
struct StoredLink {
    let sourceID: Data
    let sourcePath: String
    let ordinal: Int
    let syntax: String
    let target: String
    let fragment: String?
    let display: String?
    let embed: Bool
}

extension VaultRuntime {
    // MARK: Queries

    public func links(_ documentID: Data, direction: VaultLinkDirection, limit: Int = 50, offset: Int = 0) throws -> VaultLinkPage {
        guard (1...500).contains(limit), offset >= 0 else { throw SearchIndexError.invalidQuery }
        guard let document = try Catalog.entry(db: requireOpen().db, vaultID: vaultID, id: documentID), document.state == "live" else {
            throw DocumentCatalogError.notFound
        }
        var mentions: [VaultLinkMention]
        switch direction {
        case .outgoing:
            mentions = try storedLinks("l.entry_id=?", [.blob(documentID)]).map(mention)
        case .incoming:
            mentions = try storedLinks("l.name_key=?", [.text(LinkIndex.nameKey(document.path!))])
                .map(mention).filter { $0.documentID == documentID && $0.target != "" }
        }
        return VaultLinkPage(mentions: Array(mentions.dropFirst(offset).prefix(limit)), total: mentions.count, offset: offset)
    }

    /// Notes that mention the document's name or one of its aliases as text
    /// without linking to it.
    public func unlinkedMentions(_ documentID: Data, limit: Int = 50) throws -> [UnlinkedMention] {
        let r = try requireOpen()
        guard let document = try Catalog.entry(db: r.db, vaultID: vaultID, id: documentID), document.state == "live",
              let path = document.path else { throw DocumentCatalogError.notFound }
        var terms = [LinkIndex.withoutMarkdownExtension(path.split(separator: "/").last.map(String.init) ?? path)]
        if document.kind == "markdown", let hash = document.hash {
            let metadata = try ObsidianMetadataParser.parse(try r.objects.get(hash, maximumBytes: configuration.maximumBytes))
            let aliases = metadata.properties.first { ObsidianMetadataParser.canonicalProperty($0["name"] as? String ?? "") == "aliases" }
            terms += (aliases?["value"] as? [String]) ?? ((aliases?["value"] as? String).map { [$0] } ?? [])
        }
        let linked = Set(try links(documentID, direction: .incoming, limit: 500).mentions.map(\.sourceID))
        var seen = Set<Data>(), result: [UnlinkedMention] = []
        for term in terms where term.count >= 2 {
            for hit in try SearchIndex.search(db: r.db, vaultID: vaultID, phrase: term, limit: 500)
            where hit.entryID != documentID && !linked.contains(hit.entryID) && seen.insert(hit.entryID).inserted {
                result.append(UnlinkedMention(sourceID: hit.entryID, sourcePath: hit.path, term: term))
            }
        }
        return Array(result.sorted { $0.sourcePath < $1.sourcePath }.prefix(limit))
    }

    // MARK: Resolution

    private func storedLinks(_ condition: String, _ bindings: [SQLiteValue]) throws -> [StoredLink] {
        try requireOpen().db.queryValues("""
            SELECT l.entry_id,e.path,l.ordinal,l.syntax,l.target,l.fragment,l.display,l.embed
            FROM document_links l JOIN entries e ON e.vault_id=l.vault_id AND e.id=l.entry_id
              AND e.head_revision=l.revision_id AND e.state='live'
            WHERE l.vault_id=? AND \(condition) ORDER BY e.path,l.ordinal
            """, bindings: [.blob(vaultID)] + bindings).map { row in
            guard case .blob(let source) = row[0], case .text(let path) = row[1], case .integer(let ordinal) = row[2],
                  case .text(let syntax) = row[3], case .text(let target) = row[4], case .integer(let embed) = row[7] else {
                throw VaultRuntimeError.inconsistentCatalog
            }
            var fragment: String?, display: String?
            if case .text(let value) = row[5] { fragment = value }
            if case .text(let value) = row[6] { display = value }
            return StoredLink(sourceID: source, sourcePath: path, ordinal: Int(ordinal), syntax: syntax, target: target,
                              fragment: fragment, display: display, embed: embed != 0)
        }
    }

    private func mention(_ link: StoredLink) throws -> VaultLinkMention {
        let (status, file) = try resolve(syntax: link.syntax, target: link.target, from: link.sourcePath, sourceID: link.sourceID)
        return VaultLinkMention(sourceID: link.sourceID, sourcePath: link.sourcePath, syntax: link.syntax, target: link.target,
                                fragment: link.fragment, display: link.display, embed: link.embed, status: status,
                                documentID: file?.id, documentPath: file?.path,
                                fragmentStatus: try file.map { try fragmentStatus(link, in: $0) } ?? "unresolved")
    }

    /// Resolves a link target like Obsidian: by file name, by a path suffix
    /// ("folder/note"), or (Markdown links) relative to the source note.
    /// Several equally good matches are "ambiguous", never guessed.
    func resolve(syntax: String, target raw: String, from sourcePath: String, sourceID: Data) throws -> (String, LinkedFile?) {
        if raw.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil || raw.hasPrefix("//") {
            return ("external", nil)
        }
        var target = raw
        if syntax == "markdown" {
            guard let decoded = raw.removingPercentEncoding else { return ("unsupported", nil) }
            target = decoded
        }
        let db = try requireOpen().db
        if target.isEmpty {
            guard let source = try Catalog.entry(db: db, vaultID: vaultID, id: sourceID) else { return ("missing", nil) }
            return ("resolved", LinkedFile(id: sourceID, path: sourcePath, kind: source.kind))
        }
        guard !target.contains("\\"), target.utf8.count <= 1024,
              !target.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return ("unsupported", nil) }
        let folder = sourcePath.split(separator: "/").dropLast().map(String.init)
        if syntax == "markdown", target.hasPrefix("./") || target.hasPrefix("../") {
            var parts = folder
            for part in target.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { guard !parts.isEmpty else { return ("unsupported", nil) }; parts.removeLast(); continue }
                parts.append(String(part))
            }
            let path = parts.joined(separator: "/")
            for candidate in [path, path + ".md"] {
                if let entry = try? Catalog.live(db: db, vaultID: vaultID, path: candidate) {
                    return ("resolved", LinkedFile(id: entry.id, path: entry.path!, kind: entry.kind))
                }
            }
            return ("missing", nil)
        }
        if target.hasPrefix("/") { target.removeFirst() }
        guard !target.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return ("unsupported", nil)
        }
        let wanted = LinkIndex.fold(LinkIndex.withoutMarkdownExtension(target))
        var matches = try db.queryValues("SELECT id,path,kind FROM entries WHERE vault_id=? AND state='live' AND name_key=? ORDER BY path",
                                         bindings: [.blob(vaultID), .text(LinkIndex.nameKey(target))]).compactMap { row -> LinkedFile? in
            guard case .blob(let id) = row[0], case .text(let path) = row[1], case .text(let kind) = row[2] else { return nil }
            let key = LinkIndex.fold(LinkIndex.withoutMarkdownExtension(path))
            return key == wanted || key.hasSuffix("/" + wanted) ? LinkedFile(id: id, path: path, kind: kind) : nil
        }
        if matches.count > 1 {
            // Obsidian prefers the file next to the linking note.
            let local = LinkIndex.fold(LinkIndex.withoutMarkdownExtension((folder + [target]).joined(separator: "/")))
            matches = matches.filter { LinkIndex.fold(LinkIndex.withoutMarkdownExtension($0.path)) == local }.count == 1
                ? matches.filter { LinkIndex.fold(LinkIndex.withoutMarkdownExtension($0.path)) == local } : matches
        }
        switch matches.count {
        case 0: return ("missing", nil)
        case 1: return ("resolved", matches[0])
        default: return ("ambiguous", nil)
        }
    }

    private func fragmentStatus(_ link: StoredLink, in file: LinkedFile) throws -> String {
        guard var fragment = link.fragment else { return "none" }
        guard file.kind == "markdown" else { return "unsupported" }
        if link.syntax == "markdown" { fragment = fragment.removingPercentEncoding ?? fragment }
        guard let last = fragment.split(separator: "#").last.map(String.init), !last.isEmpty else { return "invalid" }
        let (kind, key) = last.hasPrefix("^") ? ("block", String(last.dropFirst())) : ("heading", LinkIndex.fold(last))
        let count = try requireOpen().db.queryValues("""
            SELECT count(*) FROM document_anchors a JOIN entries e ON e.vault_id=a.vault_id AND e.id=a.entry_id AND e.head_revision=a.revision_id
            WHERE a.vault_id=? AND a.entry_id=? AND a.kind=? AND a.key=?
            """, bindings: [.blob(vaultID), .blob(file.id), .text(kind), .text(key)])
        guard case .integer(let n) = count.first?.first else { return "missing" }
        return n == 1 ? "resolved" : (n == 0 ? "missing" : "ambiguous")
    }

    // MARK: Updating links when files move

    /// A link to rewrite after a move: in note `source`, link `ordinal`
    /// must keep pointing at `target`.
    struct Retarget {
        let source: Data
        let ordinal: Int
        let target: Data
    }

    /// Links that currently resolve unambiguously to `moving` files, plus
    /// relative Markdown links inside moving notes (which a move would break).
    func linksAffected(byMoving moving: [CatalogEntry]) throws -> [Retarget] {
        var result: [Retarget] = []
        for entry in moving {
            for link in try storedLinks("l.name_key=?", [.text(LinkIndex.nameKey(entry.path!))]) where link.target != "" {
                if try resolve(syntax: link.syntax, target: link.target, from: link.sourcePath, sourceID: link.sourceID).1?.id == entry.id {
                    result.append(Retarget(source: link.sourceID, ordinal: link.ordinal, target: entry.id))
                }
            }
            guard entry.kind == "markdown" else { continue }
            for link in try storedLinks("l.entry_id=? AND l.syntax='markdown'", [.blob(entry.id)]) where !link.target.hasPrefix("/") {
                if let file = try resolve(syntax: link.syntax, target: link.target, from: link.sourcePath, sourceID: link.sourceID).1,
                   file.id != entry.id {
                    result.append(Retarget(source: link.sourceID, ordinal: link.ordinal, target: file.id))
                }
            }
        }
        return result
    }

    /// Rewrites each link's target text so it resolves to its target again,
    /// in the shortest form that is unambiguous. A link that cannot be
    /// rewritten unambiguously, or a note that changed meanwhile, is left
    /// as it is. Returns the number of links rewritten.
    @discardableResult
    func retarget(_ links: [Retarget]) throws -> Int {
        let r = try requireOpen()
        var rewritten = 0
        for (source, group) in Dictionary(grouping: links, by: \.source) {
            guard let note = try Catalog.entry(db: r.db, vaultID: vaultID, id: source), note.state == "live",
                  note.kind == "markdown", let path = note.path, let head = note.head, let hash = note.hash else { continue }
            let bytes = try r.objects.get(hash, maximumBytes: configuration.maximumBytes)
            let lexed = ObsidianLinks.extract(bytes)
            var edits: [(Range<Int>, String)] = []
            for item in group where item.ordinal < lexed.count {
                let link = lexed[item.ordinal]
                guard let target = try Catalog.entry(db: r.db, vaultID: vaultID, id: item.target), let targetPath = target.path,
                      let text = try newTarget(for: link, in: path, sourceID: source, to: LinkedFile(id: target.id, path: targetPath, kind: target.kind)),
                      text != link.target else { continue }
                edits.append((link.targetRange, text))
            }
            guard !edits.isEmpty else { continue }
            var updated = [UInt8](bytes)
            for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                updated.replaceSubrange(range, with: Array(text.utf8))
            }
            do {
                try update(path, Data(updated), revision: head)
                rewritten += edits.count
            } catch VaultError.conflict {
                continue // edited meanwhile; its links are left untouched
            }
        }
        return rewritten
    }

    /// The target text for `link` (written in note `sourcePath`) that
    /// resolves unambiguously to `file`, keeping the link's style.
    private func newTarget(for link: ObsidianLink, in sourcePath: String, sourceID: Data, to file: LinkedFile) throws -> String? {
        let full = file.kind == "markdown" ? LinkIndex.withoutMarkdownExtension(file.path) : file.path
        var candidates: [String]
        if link.syntax == "wikilink" {
            let name = full.split(separator: "/").last.map(String.init) ?? full
            candidates = link.target.contains("/") ? [full] : [name, full]
        } else {
            let decoded = link.target.removingPercentEncoding ?? link.target
            let keepExtension = decoded.lowercased().hasSuffix(".md") || file.kind != "markdown"
            let destination = keepExtension ? file.path : full
            let relative = Self.relativePath(from: sourcePath, to: destination)
            let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text }
            candidates = decoded.hasPrefix("./") || decoded.hasPrefix("../") || !decoded.contains("/")
                ? [encode(relative), encode(destination)] : [encode(destination), encode(relative)]
        }
        for candidate in candidates {
            if try resolve(syntax: link.syntax, target: candidate, from: sourcePath, sourceID: sourceID).1?.id == file.id { return candidate }
        }
        return nil
    }

    /// "a/b/note.md" -> "x/y.md" gives "../../x/y.md"; same folder gives "y.md".
    static func relativePath(from source: String, to target: String) -> String {
        let from = source.split(separator: "/").dropLast().map(String.init)
        let to = target.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        let up = Array(repeating: "..", count: from.count - common)
        return (up + to[common...]).joined(separator: "/")
    }
}
