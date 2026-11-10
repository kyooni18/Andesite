import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bookmarks, in the format of Obsidian's Bookmarks core plugin
/// (`.obsidian/bookmarks.json`), so a vault keeps one list in both apps:
///
/// ```json
/// {"items": [
///   {"type": "file", "ctime": 1700000000000, "path": "Ideas.md"},
///   {"type": "file", "ctime": 1700000000001, "path": "Ideas.md", "subpath": "#Plans", "title": "Plans"},
///   {"type": "file", "ctime": 1700000000002, "path": "Ideas.md", "subpath": "#^block-id"},
///   {"type": "folder", "ctime": 1700000000003, "path": "Projects"},
///   {"type": "search", "ctime": 1700000000004, "query": "tag:#todo"},
///   {"type": "graph", "ctime": 1700000000005, "title": "Graph", "options": {}},
///   {"type": "url", "ctime": 1700000000006, "url": "https://obsidian.md", "title": "Obsidian"},
///   {"type": "group", "ctime": 1700000000007, "title": "Reading", "items": []}
/// ]}
/// ```
///
/// Headings and blocks are file bookmarks with a `subpath`. Fields this
/// type doesn't know (a graph's `options`, newer item types) are kept as
/// they are when the list is written back.
public struct Bookmark: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable {
        case file, folder, search, graph, url, group
    }

    /// Obsidian's item type; `kind` is nil for a type Andesite doesn't know.
    public var type: String
    /// When it was bookmarked, in milliseconds since 1970 (as Obsidian).
    public var ctime: Int64
    /// Vault-relative path of a file or folder bookmark.
    public var path: String?
    /// `#Heading` or `#^block-id` within the file.
    public var subpath: String?
    /// A name chosen by the user (or a group's name).
    public var title: String?
    public var query: String?
    public var url: String?
    /// A group's bookmarks.
    public var items: [Bookmark]?
    /// Fields kept for Obsidian.
    public var extra: [String: BookmarkJSON]

    public var kind: Kind? { Kind(rawValue: type) }

    public init(type: String, ctime: Int64 = Bookmark.now(), path: String? = nil, subpath: String? = nil,
                title: String? = nil, query: String? = nil, url: String? = nil, items: [Bookmark]? = nil,
                extra: [String: BookmarkJSON] = [:]) {
        self.type = type; self.ctime = ctime; self.path = path; self.subpath = subpath
        self.title = title; self.query = query; self.url = url; self.items = items; self.extra = extra
    }

    /// A note or other file; with `subpath` ("#Heading", "#^block") a place in it.
    public static func file(_ path: String, subpath: String? = nil, title: String? = nil) -> Bookmark {
        Bookmark(type: Kind.file.rawValue, path: path, subpath: subpath?.isEmpty == true ? nil : subpath, title: title)
    }
    public static func folder(_ path: String, title: String? = nil) -> Bookmark {
        Bookmark(type: Kind.folder.rawValue, path: path, title: title)
    }
    public static func search(_ query: String, title: String? = nil) -> Bookmark {
        Bookmark(type: Kind.search.rawValue, title: title, query: query)
    }
    public static func graph(title: String? = nil) -> Bookmark {
        Bookmark(type: Kind.graph.rawValue, title: title)
    }
    public static func url(_ url: String, title: String? = nil) -> Bookmark {
        Bookmark(type: Kind.url.rawValue, title: title, url: url)
    }
    public static func group(_ title: String, items: [Bookmark] = []) -> Bookmark {
        Bookmark(type: Kind.group.rawValue, title: title, items: items)
    }

    public static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// The name to show: the title, else what the bookmark points at.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .file:
            let name = (path ?? "").split(separator: "/").last.map(String.init) ?? ""
            let stem = name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
            guard let subpath, !subpath.isEmpty else { return stem }
            return stem + " › " + subpath.drop { $0 == "#" || $0 == "^" }
        case .folder: return (path ?? "").split(separator: "/").last.map(String.init) ?? (path ?? "")
        case .search: return query ?? ""
        case .graph: return "Graph"
        case .url: return url ?? ""
        case .group, nil: return title ?? type
        }
    }

    // MARK: Codable (unknown fields preserved)

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private static let known: Set<String> = ["type", "ctime", "path", "subpath", "title", "query", "url", "items"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        type = try c.decode(String.self, forKey: Key("type"))
        if let integer = try? c.decode(Int64.self, forKey: Key("ctime")) { ctime = integer }
        else { ctime = Int64((try c.decodeIfPresent(Double.self, forKey: Key("ctime"))) ?? 0) }
        path = try c.decodeIfPresent(String.self, forKey: Key("path"))
        subpath = try c.decodeIfPresent(String.self, forKey: Key("subpath"))
        title = try c.decodeIfPresent(String.self, forKey: Key("title"))
        query = try c.decodeIfPresent(String.self, forKey: Key("query"))
        url = try c.decodeIfPresent(String.self, forKey: Key("url"))
        items = try c.decodeIfPresent([Bookmark].self, forKey: Key("items"))
        var extra: [String: BookmarkJSON] = [:]
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(BookmarkJSON.self, forKey: key)
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: Key("type"))
        try c.encode(ctime, forKey: Key("ctime"))
        try c.encodeIfPresent(path, forKey: Key("path"))
        try c.encodeIfPresent(subpath, forKey: Key("subpath"))
        try c.encodeIfPresent(title, forKey: Key("title"))
        try c.encodeIfPresent(query, forKey: Key("query"))
        try c.encodeIfPresent(url, forKey: Key("url"))
        try c.encodeIfPresent(items, forKey: Key("items"))
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { try c.encode(value, forKey: Key(key)) }
    }
}

/// Any JSON value, for the fields of `bookmarks.json` that are passed through.
public enum BookmarkJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([BookmarkJSON])
    case object([String: BookmarkJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([BookmarkJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: BookmarkJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

/// A vault's bookmarks: a tree of items and groups, in order.
public struct BookmarkList: Sendable, Hashable, Codable {
    public var items: [Bookmark]

    public init(items: [Bookmark] = []) { self.items = items }

    /// Every bookmark, groups' contents included, depth first.
    public var all: [Bookmark] {
        func walk(_ items: [Bookmark]) -> [Bookmark] { items.flatMap { [$0] + walk($0.items ?? []) } }
        return walk(items)
    }

    /// The first bookmark of the file at `path` (with `subpath`, of that place in it).
    public func bookmark(forFile path: String, subpath: String? = nil) -> Bookmark? {
        all.first { $0.kind == .file && $0.path == path && ($0.subpath ?? "") == (subpath ?? "") }
    }

    public func bookmark(forFolder path: String) -> Bookmark? {
        all.first { $0.kind == .folder && $0.path == path }
    }

    // MARK: Editing

    /// Where `bookmark` is: indices from the top level down through groups.
    public func indexPath(of bookmark: Bookmark) -> [Int]? {
        func find(_ items: [Bookmark]) -> [Int]? {
            for (index, item) in items.enumerated() {
                if item == bookmark { return [index] }
                if let inner = item.items.flatMap(find) { return [index] + inner }
            }
            return nil
        }
        return find(items)
    }

    /// Adds `bookmark` at the end of the list, or of `group`.
    public mutating func add(_ bookmark: Bookmark, to group: Bookmark? = nil) throws {
        guard let group else { items.append(bookmark); return }
        guard group.kind == .group, let path = indexPath(of: group) else { throw VaultError.notFound(group.displayName) }
        modify(at: path) { $0.items = ($0.items ?? []) + [bookmark] }
    }

    /// Removes `bookmark` (a group with everything in it, as in Obsidian).
    public mutating func remove(_ bookmark: Bookmark) throws {
        guard let path = indexPath(of: bookmark) else { throw VaultError.notFound(bookmark.displayName) }
        _ = take(at: path)
    }

    /// Replaces `bookmark` with `new` where it is (to rename it, say).
    public mutating func replace(_ bookmark: Bookmark, with new: Bookmark) throws {
        guard let path = indexPath(of: bookmark) else { throw VaultError.notFound(bookmark.displayName) }
        modify(at: path) { $0 = new }
    }

    /// Moves `bookmark` into `group` (nil: the top level) at `index`
    /// (nil: the end), counted in the destination as it was before the move.
    public mutating func move(_ bookmark: Bookmark, into group: Bookmark?, at index: Int? = nil) throws {
        guard let source = indexPath(of: bookmark) else { throw VaultError.notFound(bookmark.displayName) }
        var parent: [Int] = []
        if let group {
            guard group.kind == .group, let path = indexPath(of: group) else { throw VaultError.notFound(group.displayName) }
            // A group can't go inside itself.
            guard !path.starts(with: source) else { throw VaultError.invalidPath(group.displayName) }
            parent = path
        }
        var position = index ?? Int.max
        // Taking the item out shifts what follows it in the same list.
        if Array(source.dropLast()) == parent, source.last! < position { position -= 1 }
        let item = take(at: source)
        // The group may have shifted too; find it again.
        let destination = group.flatMap { indexPath(of: $0) } ?? []
        if destination.isEmpty {
            items.insert(item, at: min(max(position, 0), items.count))
        } else {
            modify(at: destination) {
                var children = $0.items ?? []
                children.insert(item, at: min(max(position, 0), children.count))
                $0.items = children
            }
        }
    }

    /// Keeps file and folder bookmarks pointing at a file or folder that
    /// moved from `old` to `new` (vault-relative paths). Returns whether
    /// anything changed.
    @discardableResult
    public mutating func followMove(from old: String, to new: String) -> Bool {
        guard old != new, !old.isEmpty, !new.isEmpty else { return false }
        var changed = false
        func rewrite(_ items: inout [Bookmark]) {
            for index in items.indices {
                if items[index].kind == .file || items[index].kind == .folder, let path = items[index].path {
                    if path == old {
                        items[index].path = new; changed = true
                    } else if path.hasPrefix(old + "/") {
                        items[index].path = new + path.dropFirst(old.count); changed = true
                    }
                }
                if items[index].items != nil { rewrite(&items[index].items!) }
            }
        }
        rewrite(&items)
        return changed
    }

    private mutating func modify(at path: [Int], _ body: (inout Bookmark) -> Void) {
        func walk(_ items: inout [Bookmark], _ path: ArraySlice<Int>) {
            let index = path.first!
            if path.count == 1 { body(&items[index]) } else {
                var children = items[index].items ?? []
                walk(&children, path.dropFirst())
                items[index].items = children
            }
        }
        walk(&items, path[...])
    }

    private mutating func take(at path: [Int]) -> Bookmark {
        if path.count == 1 { return items.remove(at: path[0]) }
        var taken: Bookmark!
        modify(at: Array(path.dropLast())) { taken = $0.items!.remove(at: path.last!) }
        return taken
    }
}

/// Reads and writes a vault's `bookmarks.json`.
///
/// The list is Obsidian's when the vault has an `.obsidian` folder
/// (`.obsidian/bookmarks.json`, shared with Obsidian's Bookmarks plugin);
/// otherwise it is kept in `.andesite/bookmarks.json`, in the same format.
/// Like the other files in those folders, it is not indexed or synced.
public struct BookmarkStore: Sendable {
    public static let filename = "bookmarks.json"
    public let vaultDirectory: String

    public init(vaultDirectory: String) { self.vaultDirectory = vaultDirectory }

    /// The file that holds the list (which may not exist yet).
    public var path: String {
        let obsidian = vaultDirectory + "/.obsidian"
        var info = stat()
        let folder = lstat(obsidian, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            ? obsidian : vaultDirectory + "/" + VaultPathRegistry.directoryName
        return folder + "/" + Self.filename
    }

    /// The list (empty when there is no file yet).
    public func load() throws -> BookmarkList {
        try read().list
    }

    /// The list and a tag for its current contents, for compare-and-swap
    /// saves (`save(_:replacing:)`).
    public func read() throws -> (list: BookmarkList, version: String) {
        let file = path
        var info = stat()
        guard lstat(file, &info) == 0 else {
            guard errno == ENOENT else { throw VaultError.system("read bookmarks") }
            return (BookmarkList(), Self.version(nil))
        }
        // Never follow a link out of the vault.
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw VaultError.unsupported("bookmarks.json is not a regular file") }
        guard info.st_size <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let trimmed = data.filter { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        if trimmed.isEmpty { return (BookmarkList(), Self.version(data)) }
        do {
            return (try JSONDecoder().decode(BookmarkList.self, from: data), Self.version(data))
        } catch {
            throw VaultError.unsupported("bookmarks.json could not be read")
        }
    }

    /// Writes `list` atomically. With `version`, only if the file still
    /// has the contents `read` saw; otherwise `VaultError.conflict`.
    public func save(_ list: BookmarkList, replacing version: String? = nil) throws {
        let file = path
        if let version, try read().version != version { throw VaultError.conflict(current: nil) }
        let folder = String(file[..<file.lastIndex(of: "/")!])
        var info = stat()
        if lstat(folder, &info) != 0 {
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST else { throw VaultError.system("create bookmarks folder") }
        } else if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            throw VaultError.unsupported("\(folder) is not a folder")
        }
        try Self.encode(list).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// Reads the list, changes it and writes it back, as one step.
    @discardableResult
    public func update(_ body: (inout BookmarkList) throws -> Void) throws -> BookmarkList {
        let (original, version) = try read()
        var list = original
        try body(&list)
        if list != original { try save(list, replacing: version) }
        return list
    }

    /// Obsidian's layout: two-space indentation, slashes unescaped.
    public static func encode(_ list: BookmarkList) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(list)
    }

    static func version(_ data: Data?) -> String {
        guard let data else { return "none" }
        return String(ObjectStore.hash(data).prefix(32))
    }
}

extension VaultRuntime {
    /// The vault's bookmarks file.
    public var bookmarkStore: BookmarkStore { BookmarkStore(vaultDirectory: configuration.vaultDirectory) }

    /// Moves bookmarks along with a file or folder. A bookmarks file that
    /// can't be read or written never fails the move itself.
    func bookmarksFollowMove(from old: String?, to new: String?) {
        guard let old, let new, old != new else { return }
        _ = try? bookmarkStore.update { $0.followMove(from: old, to: new) }
    }
}

extension Vault {
    /// The vault's bookmarks (Obsidian's `bookmarks.json`; see `BookmarkStore`).
    public func bookmarks() async throws -> BookmarkList {
        try await perform(.read) { try $0.bookmarkStore.load() }
    }

    /// Changes the bookmarks and saves them; returns the new list. Runs on
    /// the vault's thread, so it never interleaves with a move.
    @discardableResult
    public func updateBookmarks(_ body: @escaping @Sendable (inout BookmarkList) throws -> Void) async throws -> BookmarkList {
        try await perform(.write) { try $0.bookmarkStore.update(body) }
    }
}
