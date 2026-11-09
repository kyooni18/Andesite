import Foundation
import AndesiteCore
import Hummingbird

/// The authenticated HTTP API. Each route is one backend call executed on
/// the session's owner queue; Hummingbird's event loops only parse and wait.
/// The server binds 127.0.0.1. Reach it from other machines through TLS
/// termination or a tunnel; the sync client refuses plain HTTP off-host.
public enum AndesiteHTTPServer {
    public static let maximumBody = 16 * 1024 * 1024

    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// Serves until cancelled or sent SIGINT/SIGTERM. `onReady` receives the
    /// bound port (useful with port 0).
    public static func run(session: VaultSession, token: String, port: Int,
                           onReady: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        guard isValidToken(token) else { throw APIError(.badRequest, "invalid_token") }
        let app = Application(router: router(session: session, token: token),
                              configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "Andesite"),
                              onServerRunning: { onReady($0.localAddress?.port ?? port) })
        try await app.runService()
    }

    static func router(session: VaultSession, token: String) -> Router<BasicRequestContext> {
        let router = Router()
        router.middlewares.add(BearerAuthentication(token: Array(token.utf8)))

        router.get("/v1/status") { _, _ in
            await respond(session) { vault in
                let s = try vault.status()
                return try json(["vault": s.vaultID.hex, "state": s.state, "entries": s.entries, "revisions": s.revisions,
                                 "openIncidents": s.openIncidents, "unfinishedMutations": s.unfinishedMutations])
            }
        }

        // Files, addressed by Vault-relative path.
        router.get("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond(session) { vault in
                let (document, content) = try vault.read(try required(path, "path"))
                return Reply(body: content, contentType: document.kind == "markdown" ? "text/markdown; charset=utf-8" : "application/octet-stream",
                             etag: document.revisionID.hex)
            }
        }
        router.put("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            let create = request.headers[.init("If-None-Match")!] == "*"
            let match = revision(request.headers[.init("If-Match")!])
            let body = try await Data(buffer: request.body.collect(upTo: maximumBody))
            return await respond(session) { vault in
                let path = try required(path, "path")
                if create { return try document(vault.create(path, body), status: 201) }
                guard let match else { throw APIError(.preconditionRequired, "if_match_or_if_none_match_required") }
                return try document(vault.update(path, body, revision: match))
            }
        }
        router.delete("/v1/file") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            let match = revision(request.headers[.init("If-Match")!])
            return await respond(session) { vault in
                guard let match else { throw APIError(.preconditionRequired, "if_match_required") }
                let path = try required(path, "path")
                try vault.delete(path, revision: match)
                return try json(["deleted": path])
            }
        }
        router.post("/v1/move") { request, _ in
            let fields = try await form(request)
            return await respond(session) { vault in
                try document(vault.move(required(fields["path"], "path"), to: required(fields["to"], "to"),
                                        revision: required(fields["revision"].flatMap(Data.init(hex:)), "revision")))
            }
        }
        router.post("/v1/restore") { request, _ in
            let fields = try await form(request)
            return await respond(session) { vault in
                try document(vault.restore(required(fields["path"], "path"),
                                           revision: required(fields["revision"].flatMap(Data.init(hex:)), "revision")))
            }
        }
        router.get("/v1/history") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond(session) { vault in
                try json(["revisions": try vault.history(required(path, "path")).map { r -> [String: Any] in
                    ["revision": r.id.hex, "document": r.document.hex, "parents": r.parents.map(\.hex), "path": r.path,
                     "deleted": r.deleted, "hash": r.hash ?? NSNull(), "bytes": r.size ?? NSNull(),
                     "origin": r.origin, "created": r.created]
                }])
            }
        }
        router.post("/v1/directories") { request, _ in
            let fields = try await form(request)
            return await respond(session) { vault in
                let path = try required(fields["path"], "path")
                if let to = fields["to"] { try vault.moveDirectory(path, to: to) } else { try vault.createDirectory(path) }
                return try json(["path": fields["to"] ?? path])
            }
        }

        // Index queries.
        router.get("/v1/documents") { request, _ in
            let q = request.uri.queryParameters
            let (limit, offset) = (int(q["limit"]) ?? 50, int(q["offset"]) ?? 0)
            let (tag, property, value) = (q["tag"].map(String.init), q["property"].map(String.init), q["value"].map(String.init))
            return await respond(session) { vault in
                let filter = tag == nil && property == nil && value == nil ? nil :
                    try ObsidianFilter(tag: tag, property: property, value: value)
                let page = try vault.documents(limit: limit, offset: offset, filter: filter)
                return try json(["documents": page.documents.map(documentJSON), "total": page.total,
                                 "nextOffset": page.nextOffset ?? NSNull()])
            }
        }
        router.get("/v1/search") { request, _ in
            let q = request.uri.queryParameters
            let (text, limit) = (q["q"].map(String.init) ?? "", int(q["limit"]) ?? 50)
            let (tag, property, value) = (q["tag"].map(String.init), q["property"].map(String.init), q["value"].map(String.init))
            return await respond(session) { vault in
                let search = try ObsidianSearchQuery.parse(text, explicitTag: tag, explicitProperty: property, explicitValue: value)
                let hits: [[String: Any]]
                if let phrase = search.phrase {
                    hits = try vault.searchIndexed(phrase, limit: limit, filter: search.filter).map {
                        ["document": $0.entryID.hex, "revision": $0.revisionID.hex, "title": $0.title, "path": $0.path]
                    }
                } else {
                    hits = try vault.documents(limit: min(limit, 100), filter: search.filter).documents.map(documentJSON)
                }
                return try json(["hits": hits])
            }
        }
        router.get("/v1/tags") { request, _ in
            let (limit, offset) = (int(request.uri.queryParameters["limit"]) ?? 50, int(request.uri.queryParameters["offset"]) ?? 0)
            return await respond(session) { try json($0.tags(limit: limit, offset: offset)) }
        }
        router.get("/v1/properties") { request, _ in
            let (limit, offset) = (int(request.uri.queryParameters["limit"]) ?? 50, int(request.uri.queryParameters["offset"]) ?? 0)
            return await respond(session) { try json($0.properties(limit: limit, offset: offset)) }
        }
        router.get("/v1/metadata") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond(session) { vault in
                try json(vault.documentMetadata(vault.document(required(path, "path")).id))
            }
        }
        router.get("/v1/links") { request, _ in
            let q = request.uri.queryParameters
            let path = q["path"].map(String.init), incoming = q["direction"] == "incoming"
            let (limit, offset) = (int(q["limit"]) ?? 50, int(q["offset"]) ?? 0)
            return await respond(session) { vault in
                let page = try vault.links(vault.document(required(path, "path")).id,
                                           direction: incoming ? .incoming : .outgoing, limit: limit, offset: offset)
                return try json(["links": page.mentions.map { m -> [String: Any] in
                    ["source": m.sourcePath, "target": m.target, "fragment": m.fragment ?? NSNull(),
                     "display": m.display ?? NSNull(), "embed": m.embed, "status": m.status,
                     "path": m.documentPath ?? NSNull(), "fragmentStatus": m.fragmentStatus]
                }, "total": page.total, "nextOffset": page.nextOffset ?? NSNull()])
            }
        }

        // Recovery snapshots.
        router.get("/v1/snapshots") { request, _ in
            let path = request.uri.queryParameters["path"].map(String.init)
            return await respond(session) { vault in
                try json(["snapshots": try vault.snapshots(path: path).reversed().prefix(100).map { s -> [String: Any] in
                    ["snapshot": s.id.hex, "document": s.entryID.hex, "revision": s.revisionID.hex, "path": s.originalPath,
                     "hash": s.contentHash, "bytes": s.byteLength, "reason": s.reason,
                     "created": ISO8601DateFormatter().string(from: s.createdAt)]
                }])
            }
        }
        router.get("/v1/snapshots/{id}/content") { _, context in
            let id = context.parameters.get("id").flatMap(Data.init(hex:))
            return await respond(session) { vault in
                Reply(body: try vault.snapshotContents(required(id, "id")), contentType: "text/markdown; charset=utf-8")
            }
        }
        // Sync: the feed, content objects and receiving a peer's feed.
        router.get("/v1/sync/identity") { _, _ in
            await respond(session) { try encoded($0.syncIdentity()) }
        }
        router.get("/v1/sync/changes") { request, _ in
            let q = request.uri.queryParameters
            let (after, limit) = (q["after"].flatMap { Int64($0) } ?? 0, int(q["limit"]) ?? VaultRuntime.syncPageLimit)
            return await respond(session) { try encoded($0.syncFeed(after: after, limit: limit)) }
        }
        router.post("/v1/sync/changes") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 8 * 1024 * 1024))
            return await respond(session) { vault in
                guard let batch = try? JSONDecoder().decode(SyncBatch.self, from: body) else { throw APIError(.badRequest, "invalid_json") }
                let received = try vault.receive(batch)
                var report = try vault.resolvePending()
                report.received = received
                return try encoded(report)
            }
        }
        router.post("/v1/sync/objects/missing") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 1024 * 1024))
            return await respond(session) { vault in
                guard let hashes = try? JSONDecoder().decode([String].self, from: body) else { throw APIError(.badRequest, "invalid_json") }
                return try encoded(vault.missingObjects(hashes))
            }
        }
        router.get("/v1/sync/objects/{hash}") { _, context in
            let hash = context.parameters.get("hash") ?? ""
            return await respond(session) { Reply(body: try $0.object(hash), contentType: "application/octet-stream") }
        }
        router.put("/v1/sync/objects/{hash}") { request, context in
            let hash = context.parameters.get("hash") ?? ""
            let body = try await Data(buffer: request.body.collect(upTo: maximumBody))
            return await respond(session) { vault in
                try vault.storeObject(body, hash: hash)
                return try json(["stored": hash])
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

/// Runs `work` on the owner queue and converts the result or error.
func respond(_ session: VaultSession, _ work: @escaping @Sendable (AndesiteBackend) throws -> Reply) async -> Response {
    let reply: Reply
    do { reply = try await session.perform(work) } catch { reply = failure(error) }
    var headers: HTTPFields = [.contentType: reply.contentType, .cacheControl: "no-store",
                               .init("X-Content-Type-Options")!: "nosniff"]
    if let etag = reply.etag { headers[.eTag] = "\"\(etag)\"" }
    return Response(status: .init(code: reply.status), headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: reply.body)))
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
    case SearchIndexError.invalidQuery, ObsidianIndexError.invalidQuery, VaultLinkGraphError.invalidQuery,
         DocumentCatalogError.invalidPage, DocumentCatalogError.invalidIdentifier:
        return code(400, "invalid_query")
    case VaultLinkGraphError.cacheNotReady, VaultRuntimeError.inconsistentCatalog, VaultSessionError.closed:
        return code(503, "index_not_ready")
    default: return code(500, "internal_error")
    }
}

func json(_ object: Any, status: Int = 200) throws -> Reply {
    Reply(status: status, body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
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
