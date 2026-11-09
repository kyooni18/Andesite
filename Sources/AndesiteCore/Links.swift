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
    /// The line of the source note the link is on (1-based), and that
    /// line's text shortened around the link. Only when excerpts are asked for.
    public var line: Int? = nil
    public var excerpt: String? = nil
    /// Byte range of the target in the source note.
    var range: Range<Int>? = nil
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
    /// The 1-based line holding `range` (a byte range) and that line's text,
    /// cut to about `width` characters around the range.
    static func excerpt(_ bytes: [UInt8], around range: Range<Int>, width: Int = 160) -> (Int, String) {
        let start = min(range.lowerBound, bytes.count), end = min(max(range.upperBound, start), bytes.count)
        var lineStart = start, lineEnd = end
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
        let line = bytes[..<lineStart].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        let before = String(decoding: bytes[lineStart..<start], as: UTF8.self)
        let link = String(decoding: bytes[start..<end], as: UTF8.self)
        let after = String(decoding: bytes[end..<lineEnd], as: UTF8.self)
        var head = before.trimmingCharacters(in: .whitespaces), tail = after.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = max(width - link.count, 20)
        if head.count > room / 2 { head = "…" + head.suffix(room / 2) }
        if tail.count > room - head.count { tail = tail.prefix(max(room - head.count, 0)) + "…" }
        return (line, head + link + tail)
    }

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
struct LinkedFile: Equatable, Sendable {
    let id: Data
    let path: String
    let kind: String
}

/// A stored link of a current note revision.
struct StoredLink: Sendable {
    let sourceID: Data
    let sourcePath: String
    let ordinal: Int
    let syntax: String
    let target: String
    let fragment: String?
    let display: String?
    let embed: Bool
    /// Byte range of the target in the source note.
    let range: Range<Int>
}

/// Where link resolution finds files: the catalog, or an in-memory copy of
/// it when many links are resolved at once (see `VaultGraph`). Both give
/// the same answers, so there is one set of resolution rules.
protocol LinkTargetLookup {
    /// The kind of the live file `id`, if it is live.
    func kind(of id: Data) throws -> String?
    /// The live file at `path` (compared by portability key).
    func live(path: String) throws -> LinkedFile?
    /// Live files whose name key (see `LinkIndex.nameKey`) is `key`.
    func named(_ key: String) throws -> [LinkedFile]
}

struct CatalogLinkLookup: LinkTargetLookup {
    let db: SQLiteConnection
    let vaultID: Data

    func kind(of id: Data) throws -> String? {
        try Catalog.entry(db: db, vaultID: vaultID, id: id)?.kind
    }

    func live(path: String) throws -> LinkedFile? {
        guard let entry = try? Catalog.live(db: db, vaultID: vaultID, path: path), let path = entry.path else { return nil }
        return LinkedFile(id: entry.id, path: path, kind: entry.kind)
    }

    func named(_ key: String) throws -> [LinkedFile] {
        try db.queryValues("SELECT id,path,kind FROM entries WHERE vault_id=? AND state='live' AND name_key=? ORDER BY path",
                           bindings: [.blob(vaultID), .text(key)]).compactMap { row -> LinkedFile? in
            guard case .blob(let id) = row[0], case .text(let path) = row[1], case .text(let kind) = row[2] else { return nil }
            return LinkedFile(id: id, path: path, kind: kind)
        }
    }
}

extension VaultRuntime {
    // MARK: Queries

    /// A document's outgoing links, or with `.incoming` its backlinks. With
    /// `excerpts`, each mention also gets its line and that line's text.
    public func links(_ documentID: Data, direction: VaultLinkDirection, limit: Int = 50, offset: Int = 0,
                      excerpts: Bool = false) throws -> VaultLinkPage {
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
        var page = Array(mentions.dropFirst(offset).prefix(limit))
        if excerpts { page = try withExcerpts(page) }
        return VaultLinkPage(mentions: page, total: mentions.count, offset: offset)
    }

    /// Reads each source note once and adds the line around each link.
    private func withExcerpts(_ mentions: [VaultLinkMention]) throws -> [VaultLinkMention] {
        let r = try requireOpen()
        var contents: [Data: [UInt8]] = [:]
        return try mentions.map { mention in
            guard let range = mention.range else { return mention }
            if contents[mention.sourceID] == nil {
                guard let entry = try Catalog.entry(db: r.db, vaultID: vaultID, id: mention.sourceID), let hash = entry.hash else { return mention }
                contents[mention.sourceID] = [UInt8](try r.objects.get(hash, maximumBytes: configuration.maximumBytes))
            }
            var result = mention
            (result.line, result.excerpt) = LinkIndex.excerpt(contents[mention.sourceID]!, around: range)
            return result
        }
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
            SELECT \(Self.storedLinkColumns)
            FROM document_links l JOIN entries e ON e.vault_id=l.vault_id AND e.id=l.entry_id
              AND e.head_revision=l.revision_id AND e.state='live'
            WHERE l.vault_id=? AND \(condition) ORDER BY e.path,l.ordinal
            """, bindings: [.blob(vaultID)] + bindings).map(Self.storedLink)
    }

    static let storedLinkColumns = "l.entry_id,e.path,l.ordinal,l.syntax,l.target,l.fragment,l.display,l.embed,l.start,l.end"

    static func storedLink(_ row: [SQLiteValue]) throws -> StoredLink {
        guard case .blob(let source) = row[0], case .text(let path) = row[1], case .integer(let ordinal) = row[2],
              case .text(let syntax) = row[3], case .text(let target) = row[4], case .integer(let embed) = row[7],
              case .integer(let start) = row[8], case .integer(let end) = row[9], start <= end else {
            throw VaultRuntimeError.inconsistentCatalog
        }
        var fragment: String?, display: String?
        if case .text(let value) = row[5] { fragment = value }
        if case .text(let value) = row[6] { display = value }
        return StoredLink(sourceID: source, sourcePath: path, ordinal: Int(ordinal), syntax: syntax, target: target,
                          fragment: fragment, display: display, embed: embed != 0, range: Int(start)..<Int(end))
    }

    private func mention(_ link: StoredLink) throws -> VaultLinkMention {
        let (status, file) = try resolve(syntax: link.syntax, target: link.target, from: link.sourcePath, sourceID: link.sourceID)
        return VaultLinkMention(sourceID: link.sourceID, sourcePath: link.sourcePath, syntax: link.syntax, target: link.target,
                                fragment: link.fragment, display: link.display, embed: link.embed, status: status,
                                documentID: file?.id, documentPath: file?.path,
                                fragmentStatus: try file.map { try fragmentStatus(link, in: $0) } ?? "unresolved",
                                range: link.range)
    }

    /// Resolves a link target like Obsidian: by file name, by a path suffix
    /// ("folder/note"), or (Markdown links) relative to the source note.
    /// Several equally good matches are "ambiguous", never guessed.
    func resolve(syntax: String, target raw: String, from sourcePath: String, sourceID: Data) throws -> (String, LinkedFile?) {
        try Self.resolve(syntax: syntax, target: raw, from: sourcePath, sourceID: sourceID,
                         in: CatalogLinkLookup(db: requireOpen().db, vaultID: vaultID))
    }

    static func resolve(syntax: String, target raw: String, from sourcePath: String, sourceID: Data,
                        in files: some LinkTargetLookup) throws -> (String, LinkedFile?) {
        if raw.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil || raw.hasPrefix("//") {
            return ("external", nil)
        }
        var target = raw
        if syntax == "markdown" {
            guard let decoded = raw.removingPercentEncoding else { return ("unsupported", nil) }
            target = decoded
        }
        if target.isEmpty {
            guard let kind = try files.kind(of: sourceID) else { return ("missing", nil) }
            return ("resolved", LinkedFile(id: sourceID, path: sourcePath, kind: kind))
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
                if let file = try files.live(path: candidate) { return ("resolved", file) }
            }
            return ("missing", nil)
        }
        if target.hasPrefix("/") { target.removeFirst() }
        guard !target.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return ("unsupported", nil)
        }
        let wanted = LinkIndex.fold(LinkIndex.withoutMarkdownExtension(target))
        var matches = try files.named(LinkIndex.nameKey(target)).filter { file in
            let key = LinkIndex.fold(LinkIndex.withoutMarkdownExtension(file.path))
            return key == wanted || key.hasSuffix("/" + wanted)
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
