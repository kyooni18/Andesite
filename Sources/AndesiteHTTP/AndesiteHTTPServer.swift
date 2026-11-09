import Foundation
import AndesiteCore
import Hummingbird
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The authenticated HTTP API over one `Vault`. Hummingbird's event loops
/// only parse and wait; the vault runs each call on its own thread.
/// The server binds 127.0.0.1. Reach it from other machines through TLS
/// termination or a tunnel; the sync client refuses plain HTTP off-host.
public enum AndesiteHTTPServer {
    /// Largest file accepted by PUT /v1/file; the Vault's own limits also apply.
    public static let maximumUpload = 4 * 1024 * 1024 * 1024

    /// Longest a `GET /sync/changes?wait=` request is held, in seconds.
    public static let maximumSyncWait = 55

    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// Serves until cancelled or sent SIGINT/SIGTERM. `onReady` receives the
    /// bound port (useful with port 0).
    public static func run(vault: Vault, token: String, port: Int,
                           onReady: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        guard isValidToken(token) else { throw APIError(.badRequest, "invalid_token") }
        let app = Application(router: router(vault: vault, token: token),
                              configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "Andesite"),
                              onServerRunning: { onReady($0.localAddress?.port ?? port) })
        try await app.runService()
    }

    /// Routes map onto `Vault` methods, which set each call's priority:
    /// document and index routes are user requests; sync routes, which
    /// serve a peer's background sync, are background work.
    static func router(vault: Vault, token: String) -> Router<BasicRequestContext> {
        let router = Router()
        router.middlewares.add(BearerAuthentication(token: Array(token.utf8)))

        router.get("/v1/status") { _, _ in
            await respond {
                let s = try await vault.status()
                return try json(["vault": s.vaultID.hex, "state": s.state, "entries": s.entries, "revisions": s.revisions,
                                 "openIncidents": s.openIncidents, "unfinishedMutations": s.unfinishedMutations])
            }
        }

        // Files, addressed by Vault-relative path.
        router.get("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            let opened: OpenedContent
            do {
                let path = try required(path, "path")
                opened = try await vault.perform(.read) { runtime in
                    let (document, descriptor) = try runtime.openContent(path)
                    return OpenedContent(document: document, descriptor: descriptor)
                }
            } catch { return response(failure(error)) }
            return stream(opened)
        }
        router.put("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            let create = request.headers[.init("If-None-Match")!] == "*"
            let match = revision(request.headers[.init("If-Match")!])
            // Stage the body off the vault's thread; the backend then
            // streams it into the object store.
            let staged: URL
            do { staged = try await stage(request.body, in: vault.stateDirectory) } catch { return response(failure(error)) }
            defer { try? FileManager.default.removeItem(at: staged) }
            return await respond {
                let path = try required(path, "path")
                if create { return try document(await vault.create(path, contentsOf: staged), status: 201) }
                guard let match else { throw APIError(.preconditionRequired, "if_match_or_if_none_match_required") }
                return try document(await vault.update(path, contentsOf: staged, revision: match))
            }
        }
        router.delete("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            let match = revision(request.headers[.init("If-Match")!])
            return await respond {
                guard let match else { throw APIError(.preconditionRequired, "if_match_required") }
                let path = try required(path, "path")
                try await vault.delete(path, revision: match)
                return try json(["deleted": path])
            }
        }
        router.post("/v1/move") { request, _ in
            let fields = try await form(request)
            return await respond {
                try document(await vault.move(required(fields["path"], "path"), to: required(fields["to"], "to"),
                                              revision: required(fields["revision"].flatMap(Data.init(hex:)), "revision"),
                                              updateLinks: fields["updateLinks"] != "false"))
            }
        }
        router.post("/v1/restore") { request, _ in
            let fields = try await form(request)
            return await respond {
                try document(await vault.restore(required(fields["path"], "path"),
                                                 revision: required(fields["revision"].flatMap(Data.init(hex:)), "revision")))
            }
        }
        router.get("/v1/history") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond {
                try json(["revisions": try await vault.history(required(path, "path")).map { r -> [String: Any] in
                    ["revision": r.id.hex, "document": r.document.hex, "parents": r.parents.map(\.hex), "path": r.path,
                     "deleted": r.deleted, "hash": r.hash ?? NSNull(), "bytes": r.size ?? NSNull(),
                     "origin": r.origin, "created": r.created]
                }])
            }
        }
        router.post("/v1/directories") { request, _ in
            let fields = try await form(request)
            return await respond {
                let path = try required(fields["path"], "path")
                if let to = fields["to"] {
                    try await vault.moveDirectory(path, to: to, updateLinks: fields["updateLinks"] != "false")
                } else { try await vault.createDirectory(path) }
                return try json(["path": fields["to"] ?? path])
            }
        }

        // Index queries.
        router.get("/v1/documents") { request, _ in
            let q = request.uri.queryParameters
            let (limit, offset) = (int(q["limit"]) ?? 50, int(q["offset"]) ?? 0)
            let (tag, property, value) = (q["tag"].map(String.init), q["property"].map(String.init), q["value"].map(String.init))
            return await respond {
                let filter = tag == nil && property == nil && value == nil ? nil :
                    try ObsidianFilter(tag: tag, property: property, value: value)
                let page = try await vault.documents(limit: limit, offset: offset, filter: filter)
                return try json(["documents": page.documents.map(documentJSON), "total": page.total,
                                 "nextOffset": page.nextOffset.map { $0 as Any } ?? NSNull()])
            }
        }
        router.get("/v1/search") { request, _ in
            let q = request.uri.queryParameters
            let (text, limit) = (q["q"].map(String.init) ?? "", int(q["limit"]) ?? 50)
            let (tag, property, value) = (q["tag"].map(String.init), q["property"].map(String.init), q["value"].map(String.init))
            return await respond {
                let search = try ObsidianSearchQuery.parse(text, explicitTag: tag, explicitProperty: property, explicitValue: value)
                let hits: [[String: Any]]
                if let phrase = search.phrase {
                    hits = try await vault.search(phrase, limit: limit, filter: search.filter).map {
                        ["document": $0.entryID.hex, "revision": $0.revisionID.hex, "title": $0.title, "path": $0.path]
                    }
                } else {
                    hits = try await vault.documents(limit: min(limit, 100), filter: search.filter).documents.map(documentJSON)
                }
                return try json(["hits": hits])
            }
        }
        router.get("/v1/tags") { request, _ in
            let (limit, offset) = (int(request.uri.queryParameters["limit"]) ?? 50, int(request.uri.queryParameters["offset"]) ?? 0)
            return await respond { try encoded(await vault.tags(limit: limit, offset: offset)) }
        }
        router.get("/v1/properties") { request, _ in
            let (limit, offset) = (int(request.uri.queryParameters["limit"]) ?? 50, int(request.uri.queryParameters["offset"]) ?? 0)
            return await respond { try encoded(await vault.properties(limit: limit, offset: offset)) }
        }
        router.get("/v1/metadata") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond { try encoded(await vault.metadata(required(path, "path"))) }
        }
        router.get("/v1/mentions") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond {
                try json(["mentions": try await vault.unlinkedMentions(required(path, "path")).map {
                    ["source": $0.sourcePath, "term": $0.term]
                }])
            }
        }
        // Frontmatter edits: {"path","revision","name","value"} (a null value removes the property).
        router.post("/v1/properties") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 256 * 1024))
            return await respond {
                guard let edit = try? JSONDecoder().decode(PropertyEdit.self, from: body),
                      let revision = Data(hex: edit.revision) else { throw APIError(.badRequest, "invalid_json") }
                return try document(await vault.setProperty(edit.path, edit.name, to: edit.value, revision: revision))
            }
        }
        // {"path","revision","add"} or {"path","revision","remove"}.
        router.post("/v1/tags") { request, _ in
            let fields = try await form(request)
            return await respond {
                let path = try required(fields["path"], "path")
                let revision = try required(fields["revision"].flatMap(Data.init(hex:)), "revision")
                if let tag = fields["add"] { return try document(await vault.addTag(path, tag, revision: revision)) }
                return try document(await vault.removeTag(path, required(fields["remove"], "add_or_remove"), revision: revision))
            }
        }
        router.get("/v1/links") { request, _ in
            let q = request.uri.queryParameters
            let path = q["path"].map(String.init), incoming = q["direction"] == "incoming"
            let (limit, offset) = (int(q["limit"]) ?? 50, int(q["offset"]) ?? 0)
            return await respond {
                let page = try await vault.links(required(path, "path"), direction: incoming ? .incoming : .outgoing,
                                                 limit: limit, offset: offset)
                return try json(["links": page.mentions.map { m -> [String: Any] in
                    ["source": m.sourcePath, "target": m.target, "fragment": m.fragment ?? NSNull(),
                     "display": m.display ?? NSNull(), "embed": m.embed, "status": m.status,
                     "path": m.documentPath ?? NSNull(), "fragmentStatus": m.fragmentStatus]
                }, "total": page.total, "nextOffset": page.nextOffset.map { $0 as Any } ?? NSNull()])
            }
        }

        // Recovery snapshots.
        router.get("/v1/snapshots") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond {
                try json(["snapshots": try await vault.snapshots(path: path).reversed().prefix(100).map { s -> [String: Any] in
                    ["snapshot": s.id.hex, "document": s.entryID.hex, "revision": s.revisionID.hex, "path": s.originalPath,
                     "hash": s.contentHash, "bytes": s.byteLength, "reason": s.reason,
                     "created": ISO8601DateFormatter().string(from: s.createdAt)]
                }])
            }
        }
        router.get("/v1/snapshots/{id}/content") { _, context in
            let id = context.parameters.get("id").flatMap(Data.init(hex:))
            return await respond {
                Reply(body: try await vault.snapshotContents(required(id, "id")), contentType: "text/markdown; charset=utf-8")
            }
        }
        // Sync: the feed, content objects and receiving a peer's feed.
        router.get("/sync/identity") { _, _ in
            await respond { try encoded(await vault.perform(.background) { try $0.syncIdentity() }) }
        }
        router.get("/sync/changes") { request, _ in
            let q = request.uri.queryParameters
            let (after, limit) = (q["after"].flatMap { Int64($0) } ?? 0, int(q["limit"]) ?? VaultRuntime.syncPageLimit)
            // With `wait`, hold the request until the feed moves past `after`
            // (at most `maximumSyncWait` seconds), so clients learn of
            // changes at once instead of on their next poll.
            let wait = min(max(int(q["wait"]) ?? 0, 0), maximumSyncWait)
            return await respond {
                let deadline = ContinuousClock.now + .seconds(wait)
                while wait > 0, ContinuousClock.now < deadline,
                      try await vault.perform(.background, { try $0.syncHead() }) <= after {
                    try await Task.sleep(for: .milliseconds(200))
                }
                return try encoded(await vault.perform(.background) { try $0.syncFeed(after: after, limit: limit) })
            }
        }
        router.post("/sync/changes") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 8 * 1024 * 1024))
            return await respond {
                guard let batch = try? JSONDecoder().decode(SyncBatch.self, from: body) else { throw APIError(.badRequest, "invalid_json") }
                return try encoded(await vault.perform(.background) { runtime in
                    let received = try runtime.receive(batch)
                    var report = try runtime.resolvePending()
                    report.received = received
                    return report
                })
            }
        }
        router.post("/sync/objects/missing") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 1024 * 1024))
            return await respond {
                guard let hashes = try? JSONDecoder().decode([String].self, from: body) else { throw APIError(.badRequest, "invalid_json") }
                return try encoded(await vault.perform(.background) { try $0.missingObjects(hashes) })
            }
        }
        router.post("/sync/objects/fetch") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 1024 * 1024))
            return await respond {
                guard let hashes = try? JSONDecoder().decode([String].self, from: body) else { throw APIError(.badRequest, "invalid_json") }
                return Reply(body: try await vault.perform(.background) { try $0.objectBundle(hashes) },
                             contentType: "application/octet-stream")
            }
        }
        router.post("/sync/objects/bundle") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: VaultRuntime.chunkLimit + 1024 * 1024))
            return await respond {
                try json(["received": try await vault.perform(.background) { try $0.receiveBundle(body) }])
            }
        }
        router.get("/sync/objects/{hash}") { request, context in
            let hash = context.parameters.get("hash") ?? ""
            let q = request.uri.queryParameters
            let (offset, length) = (q["offset"].flatMap { Int64($0) } ?? 0, int(q["length"]) ?? VaultRuntime.chunkLimit)
            return await respond {
                Reply(body: try await vault.perform(.background) { try $0.objectChunk(hash, offset: offset, length: length) },
                      contentType: "application/octet-stream")
            }
        }
        router.put("/sync/objects/{hash}") { request, context in
            let hash = context.parameters.get("hash") ?? ""
            let q = request.uri.queryParameters
            let size = q["size"].flatMap { Int64($0) }, offset = q["offset"].flatMap { Int64($0) } ?? 0
            let digest = request.headers[.init("X-Chunk-SHA256")!]
            let body = try await Data(buffer: request.body.collect(upTo: VaultRuntime.chunkLimit))
            return await respond {
                guard digest == nil || digest == ObjectStore.hash(body) else { throw APIError(.badRequest, "chunk_hash_mismatch") }
                let size = try required(size, "size")
                let received = try await vault.perform(.background) { try $0.receiveChunk(hash, size: size, offset: offset, body) }
                return try encoded(ObjectProgress(hash: hash, received: received))
            }
        }
        return router
    }
}

// MARK: - Plumbing

struct APIError: Error {
    let status: HTTPResponse.Status
    let code: String
    init(_ status: HTTPResponse.Status, _ code: String) { self.status = status; self.code = code }
}

struct Reply: Sendable {
    var status = 200
    var body: Data
    var contentType = "application/json; charset=utf-8"
    var etag: String?
}

/// Runs a route's work and converts its result or error.
func respond(_ work: () async throws -> Reply) async -> Response {
    do { return response(try await work()) } catch { return response(failure(error)) }
}

func response(_ reply: Reply) -> Response {
    var headers: HTTPFields = [.contentType: reply.contentType, .cacheControl: "no-store",
                               .init("X-Content-Type-Options")!: "nosniff"]
    if let etag = reply.etag { headers[.eTag] = "\"\(etag)\"" }
    return Response(status: .init(code: reply.status), headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: reply.body)))
}

struct OpenedContent: Sendable {
    let document: IndexedDocument
    let descriptor: Int32
}

/// Streams stored content without loading it into memory.
func stream(_ file: OpenedContent) -> Response {
    let fd = file.descriptor
    let body = ResponseBody(contentLength: file.document.byteLength) { writer in
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw APIError(.internalServerError, "read_failed") }
            if n == 0 { break }
            try await writer.write(ByteBuffer(bytes: buffer[0..<n]))
        }
        try await writer.finish(nil)
    }
    let type = file.document.kind == "markdown" ? "text/markdown; charset=utf-8" : "application/octet-stream"
    return Response(status: .ok, headers: [.contentType: type, .cacheControl: "no-store", .eTag: "\"\(file.document.revisionID.hex)\"",
                                           .init("X-Content-Type-Options")!: "nosniff"], body: body)
}

/// Writes a request body to a private file under `<state>/uploads`.
func stage(_ body: RequestBody, in stateDirectory: String) async throws -> URL {
    let directory = URL(fileURLWithPath: stateDirectory).appendingPathComponent("uploads")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(UUID().uuidString)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw APIError(.internalServerError, "staging_failed") }
    defer { close(fd) }
    do {
        var total = 0
        for try await buffer in body {
            total += buffer.readableBytes
            guard total <= AndesiteHTTPServer.maximumUpload else { throw VaultError.tooLarge }
            try buffer.withUnsafeReadableBytes { raw in
                var written = 0
                while written < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw APIError(.init(code: 507), "staging_failed") }
                    written += n
                }
            }
        }
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
    return url
}

func failure(_ error: Error) -> Reply {
    func code(_ status: Int, _ code: String, _ extra: [String: Any] = [:]) -> Reply {
        var body = extra
        body["error"] = code
        return Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data())
    }
    switch error {
    case let e as APIError: return code(e.status.code, e.code)
    case VaultError.notFound, DocumentCatalogError.notFound, SnapshotError.notFound: return code(404, "not_found")
    case VaultError.alreadyExists: return code(409, "already_exists")
    case VaultError.conflict(let current): return code(412, "revision_conflict", ["current": current?.hex ?? NSNull()])
    case VaultError.invalidPath: return code(400, "invalid_path")
    case VaultError.tooLarge: return code(413, "too_large")
    case VaultError.unsupported: return code(422, "unsupported")
    case SyncError.invalidBatch(let reason): return code(400, "invalid_sync_batch", ["reason": reason])
    case SyncError.historyGap: return code(409, "history_gap")
    case SyncError.missingObject(let hash): return code(409, "missing_object", ["hash": hash])
    case SearchIndexError.invalidQuery, ObsidianIndexError.invalidQuery,
         DocumentCatalogError.invalidPage, DocumentCatalogError.invalidIdentifier:
        return code(400, "invalid_query")
    case _ where VaultError.isStorageFull(error): return code(507, "storage_full")
    case VaultRuntimeError.indexNotReady, VaultRuntimeError.inconsistentCatalog, VaultRuntimeError.closed:
        return code(503, "index_not_ready")
    default: return code(500, "internal_error")
    }
}

func json(_ object: Any, status: Int = 200) throws -> Reply {
    Reply(status: status, body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

/// `{"path","name","revision","value"}`; a null or missing value removes the property.
struct PropertyEdit: Decodable {
    let path: String
    let name: String
    let revision: String
    let value: PropertyValue?

    enum CodingKeys: String, CodingKey { case path, name, revision, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        revision = try c.decode(String.self, forKey: .revision)
        if try !c.contains(.value) || c.decodeNil(forKey: .value) { value = nil }
        else if let flag = try? c.decode(Bool.self, forKey: .value) { value = .bool(flag) }
        else if let number = try? c.decode(Double.self, forKey: .value) { value = .number(number) }
        else if let text = try? c.decode(String.self, forKey: .value) { value = .text(text) }
        else { value = .list(try c.decode([String].self, forKey: .value)) }
    }
}

func encoded<T: Encodable>(_ value: T) throws -> Reply {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Reply(body: try encoder.encode(value))
}

func documentJSON(_ d: IndexedDocument) -> [String: Any] {
    ["document": d.id.hex, "revision": d.revisionID.hex, "path": d.path, "title": d.title,
     "hash": d.hash, "bytes": d.byteLength, "kind": d.kind]
}

func document(_ d: IndexedDocument, status: Int = 200) throws -> Reply {
    var reply = try json(documentJSON(d), status: status)
    reply.etag = d.revisionID.hex
    return reply
}

func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw APIError(.badRequest, "\(name)_required") }
    return value
}

func int(_ value: Substring?) -> Int? { value.flatMap { Int($0) } }

/// `"32-hex-digits"` (an entity tag) -> revision bytes.
func revision(_ header: String?) -> Data? {
    guard let header, header.count == 34, header.hasPrefix("\""), header.hasSuffix("\"") else { return nil }
    return Data(hex: String(header.dropFirst().dropLast())).flatMap { $0.count == 16 ? $0 : nil }
}

/// A small JSON object of strings, as sent by POST routes.
func form(_ request: Request) async throws -> [String: String] {
    let body = try await request.body.collect(upTo: 64 * 1024)
    guard let object = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: String] else {
        throw APIError(.badRequest, "invalid_json")
    }
    return object
}

extension Data {
    init(buffer: ByteBuffer) { self.init(buffer.readableBytesView) }
}

/// Requires the whole bearer token, compared in constant time.
struct BearerAuthentication: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: [UInt8]

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let header = request.headers[.authorization] ?? ""
        let proposed = Array((header.hasPrefix("Bearer ") ? header.dropFirst(7) : "").utf8)
        var difference = UInt8(truncatingIfNeeded: proposed.count ^ token.count)
        for index in 0..<token.count { difference |= token[index] ^ (index < proposed.count ? proposed[index] : 0) }
        guard difference == 0 else {
            return Response(status: .unauthorized, headers: [.contentType: "application/json; charset=utf-8"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"error\":\"authentication_required\"}")))
        }
        do {
            return try await next(request, context)
        } catch let error as APIError {
            return Response(status: error.status, headers: [.contentType: "application/json; charset=utf-8"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.code)\"}")))
        }
    }
}
