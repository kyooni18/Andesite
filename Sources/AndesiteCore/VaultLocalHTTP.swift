#if os(macOS)
import Foundation
import Darwin
import CAndesiteFS

public enum VaultLocalHTTPError: Error, Equatable {
    case cannotBind(Int32)
    case cannotAccept(Int32)
}

public struct VaultHTTPResponse {
    public let status: Int
    public let contentType: String
    public let body: Data

    init(status: Int, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    static func json(_ status: Int = 200, _ value: [String: Any]) -> VaultHTTPResponse {
        // All responses use internally constructed JSON values; never
        // concatenate untrusted note names into protocol syntax.
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return VaultHTTPResponse(status: 500, body: Data("{\"error\":\"serialization_failed\"}".utf8))
        }
        guard bytes.count <= 1024 * 1024 else {
            return VaultHTTPResponse(status: 413,
                body: Data("{\"error\":\"response_too_large\"}".utf8))
        }
        return VaultHTTPResponse(status: status, body: bytes)
    }

    static func error(_ status: Int, _ code: String) -> VaultHTTPResponse {
        json(status, ["error": code])
    }
}

/// Bounded HTTP/1.1 GET, conditional PUT and replica inbox POST over a private
/// Unix domain socket in the already
/// validated 0700 state directory. The OS verifies same-UID peer credentials.
/// No TCP listener, extra database connection, executor, or background thread.
public final class VaultLocalHTTP {
    private let backend: AndesiteBackend
    private let server: OpaquePointer
    public static let socketName = "andesite-read.sock"
    private let maximumHeaders = 8192
    private let maximumEditBody = 256 * 1024
    private let maximumResponse = 1024 * 1024
    public let socketPath: String

    public static func socketPath(for stateDirectory: String) throws -> String {
        var result = [CChar](repeating: 0, count: 256)
        guard stateDirectory.withCString({
            andesite_local_http_resolve_path($0, &result, UInt(result.count))
        }) == 0 else { throw VaultLocalHTTPError.cannotBind(errno) }
        return String(decoding: result.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public init(runtime: VaultRuntime, stateDirectory: String) throws {
        let path = try Self.socketPath(for: stateDirectory)
        guard let socket = stateDirectory.withCString({ andesite_local_http_open($0) }) else {
            throw VaultLocalHTTPError.cannotBind(errno)
        }
        self.backend = runtime
        self.server = socket
        self.socketPath = path
    }

    deinit { andesite_local_http_close(server) }

    /// Process at most one pending client per loop. Read timeout and response
    /// budgets bound the impact of a stalled client on file observation.
    public func poll(indexReady: Bool) throws {
        let client = andesite_local_http_accept(server)
        if client == -2 || client == -3 { return }
        guard client >= 0 else { throw VaultLocalHTTPError.cannotAccept(errno) }
        defer { _ = Darwin.close(client) }

        var request = [CChar](repeating: 0, count: maximumHeaders + maximumEditBody)
        let length = request.withUnsafeMutableBufferPointer {
            andesite_local_http_read_request(client, $0.baseAddress, UInt($0.count))
        }
        let response: VaultHTTPResponse
        if length <= 0 {
            response = .error(400, "invalid_request")
        } else {
            let raw = Data(request.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            response = handle(request: raw, indexReady: indexReady)
        }
        write(response, to: client)
    }

    private func write(_ response: VaultHTTPResponse, to client: Int32) {
        let messages: [Int: String] = [
            200: "OK", 400: "Bad Request", 404: "Not Found",
            405: "Method Not Allowed", 409: "Conflict",
            412: "Precondition Failed", 413: "Content Too Large",
            422: "Unprocessable Content", 428: "Precondition Required",
            503: "Service Unavailable", 500: "Internal Server Error"
        ]
        var head = "HTTP/1.1 \(response.status) \(messages[response.status] ?? "Error")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        if response.status == 405 { head += "Allow: GET\r\n" }
        head += "\r\n"
        var packet = Data(head.utf8)
        packet.append(response.body)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        packet.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count && ProcessInfo.processInfo.systemUptime < deadline {
                let sent = Darwin.send(client, base.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                if sent <= 0 { break }
                offset += sent
            }
        }
    }

    private func id(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "").lowercased()
        guard value.utf8.count == 32, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for i in stride(from: 0, to: value.utf8.count, by: 2) {
            let first = value.index(value.startIndex, offsetBy: i)
            let last = value.index(first, offsetBy: 2)
            guard let number = UInt8(value[first..<last], radix: 16) else { return nil }
            bytes.append(number)
        }
        return Data(bytes)
    }

    private func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func metadata(_ s: RecoverySnapshot) -> [String: Any] {
        [
            "snapshot": hex(s.id),
            "document": hex(s.entryID),
            "revision": hex(s.revisionID),
            "path": s.originalPath,
            "state": s.documentState,
            "hash": s.contentHash,
            "bytes": s.byteLength,
            "created": ISO8601DateFormatter().string(from: s.createdAt),
            "expires": ISO8601DateFormatter().string(from: s.expiresAt),
            "eligible": s.isExpired(),
            "reason": s.reason,
            "observedAt": s.observedAt
        ]
    }

    private func documentJSON(_ d: IndexedDocument) -> [String: Any] {
        [
            "document": hex(d.id), "revision": hex(d.revisionID), "path": d.path,
            "title": d.title, "hash": d.hash, "bytes": d.byteLength
        ]
    }

    private func preview(_ id: Data, of d: IndexedDocument) throws -> [String: Any] {
        var detail: [String: Any] = [
            "document": documentJSON(d),
            "metadata": try backend.documentMetadata(id),
            "structureAvailable": false,
            "source": "last_completed_reconciliation"
        ]
        let maximumStructureBytes = 256 * 1024
        if d.byteLength > maximumStructureBytes {
            detail["structureReason"] = "too_large_for_outline"
            return detail
        }
        let bytes = try backend.documentContents(id, maximumBytes: maximumStructureBytes)
        let parsed = try ObsidianMetadataParser.parse(bytes)
        let facts = try MarkdownAnalyzer.analyze(Data(parsed.body.utf8))
        let wiki = ObsidianLinks.extract(parsed.body)
        detail["structureTruncated"] = facts.headings.count > 256 ||
            facts.linkDestinations.count > 256 || wiki.count > 256
        detail["headings"] = facts.headings.prefix(256).map { heading -> [String: Any] in
            [
                "level": heading.level, "text": String(heading.text.prefix(512)),
                 "startLine": heading.startLine.map { ($0 + parsed.bodyLineOffset) as Any } ?? NSNull(),
                "endLine": heading.endLine.map { ($0 + parsed.bodyLineOffset) as Any } ?? NSNull()
            ]
        }
        // These are lexical references, NOT resolved Obsidian links.
        detail["markdownLinks"] = facts.linkDestinations.prefix(256).map {
            String($0.prefix(1024))
        }
        detail["wikilinks"] = wiki.prefix(256).map { link -> [String: Any] in
            [
                "target": String(link.target.prefix(1024)),
                "fragment": link.fragment.map { String($0.prefix(512)) as Any } ?? NSNull(),
                "alias": link.alias.map { String($0.prefix(512)) as Any } ?? NSNull(),
                "embed": link.embed
            ]
        }
        detail["structureAvailable"] = true
        return detail
    }

    private func linkJSON(_ link: VaultLinkMention) -> [String: Any] {
        [
            "source": hex(link.sourceID), "sourcePath": link.sourcePath,
            "syntax": link.syntax, "target": link.target,
            "fragment": link.fragment.map { $0 as Any } ?? NSNull(),
            "display": link.display.map { $0 as Any } ?? NSNull(),
            "embed": link.embed, "status": link.status,
            "document": link.documentID.map { hex($0) as Any } ?? NSNull(),
            "path": link.documentPath.map { $0 as Any } ?? NSNull(),
            "fragmentStatus": link.fragmentStatus,
            "aliasSuggestions": link.aliasSuggestions
        ]
    }

    private func queryParameters(_ raw: String) -> [String: String]? {
        if raw.isEmpty { return [:] }
        var parameters: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            func decode(_ token: Substring) -> String? {
                let replaced = token.replacingOccurrences(of: "+", with: " ")
                guard let decoded = replaced.removingPercentEncoding,
                      !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                    return nil
                }
                return decoded
            }
            guard let key = decode(parts[0]), let value = decode(parts[1]),
                  !key.isEmpty, parameters[key] == nil else { return nil }
            parameters[key] = value
        }
        return parameters
    }

    private func limit(_ value: String?, default fallback: Int = 50) -> Int? {
        guard let value else { return fallback }
        guard value.utf8.count <= 3, !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let n = Int(value), (1...100).contains(n) else { return nil }
        return n
    }

    private func validatedOffset(_ text: String?) -> Int? {
        guard let text else { return 0 }
        guard !text.isEmpty, text.utf8.count <= 6,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), number <= 100_000 else { return nil }
        return number
    }

    private func validatedFilter(_ args: [String: String]) throws -> ObsidianFilter? {
        if args["tag"] == nil && args["property"] == nil && args["value"] == nil {
            return nil
        }
        return try ObsidianFilter(tag: args["tag"], property: args["property"],
                                  value: args["value"])
    }

    /// Internal pure request decoding, with runtime access restricted to the
    /// synchronous watcher owner. Does not read current source files.
    func handle(request: Data, indexReady: Bool) -> VaultHTTPResponse {
        let boundary = Data([13, 10, 13, 10])
        guard request.count <= maximumHeaders + maximumEditBody,
              let delimiter = request.range(of: boundary),
              delimiter.upperBound <= maximumHeaders,
              let raw = String(data: request.prefix(upTo: delimiter.upperBound),
                               encoding: .utf8),
              !raw.contains("\0") else { return .error(400, "invalid_request") }
        let body = Data(request.suffix(from: delimiter.upperBound))
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .error(400, "invalid_request") }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1",
              first.utf8.count <= 4096 else { return .error(400, "invalid_request") }
        let method = String(words[0])
        guard method == "GET" || method == "PUT" || method == "POST" else {
            return .error(405, "method_not_allowed")
        }
        if method == "POST" {
            guard words[1] == "/v1/sync/changes" ||
                  words[1] == "/v1/sync/snapshots" else {
                return .error(405, "method_not_allowed")
            }
        }

        var hostCount = 0
        var contentLength: Int?
        var contentType: String?
        var ifMatch: String?
        for header in lines.dropFirst().dropLast(2) {
            guard let separator = header.firstIndex(of: ":"), header.first != " ",
                  header.first != "\t" else { return .error(400, "invalid_headers") }
            let name = header[..<separator]
            guard !name.isEmpty, name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45
            }) else { return .error(400, "invalid_headers") }
            let value = String(header[header.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "host":
                hostCount += 1
                guard !value.isEmpty else { return .error(400, "invalid_headers") }
            case "content-length":
                guard (method == "PUT" || method == "POST"),
                      contentLength == nil, !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(value), count <= maximumEditBody else {
                    return .error(400, "invalid_content_length")
                }
                contentLength = count
            case "content-type":
                guard (method == "PUT" || method == "POST"), contentType == nil else {
                    return .error(400, "invalid_content_type")
                }
                contentType = value
            case "if-match":
                guard method == "PUT", ifMatch == nil else {
                    return .error(400, "invalid_precondition")
                }
                ifMatch = value
            case "transfer-encoding", "expect", "upgrade":
                return .error(400, "unsupported_request_framing")
            default: break
            }
        }
        guard hostCount == 1 else { return .error(400, "invalid_headers") }
        if method == "GET" {
            guard body.isEmpty else { return .error(400, "request_body_not_supported") }
        } else {
            guard let count = contentLength, count == body.count,
                  contentType == (method == "PUT" ?
                    "text/markdown; charset=utf-8" :
                    "application/json; charset=utf-8") else {
                return .error(400, "invalid_request_body")
            }
        }

        let target = String(words[1])
        let fragments = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(fragments[0])
        guard path.hasPrefix("/"), !path.contains("%"),
              !path.contains("#"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let args = queryParameters(fragments.count > 1 ? String(fragments[1]) : "") else {
            return .error(400, "invalid_target")
        }

        do {
            if method == "POST" {
                guard args.isEmpty else { return .error(400, "invalid_sync_request") }
                if path == "/v1/sync/inbox/changes" {
                guard Set(args.keys).isSubset(of: ["source", "epoch", "after", "limit"]),
                      let source = args["source"], let epoch = args["epoch"],
                      let afterText = args["after"],
                      !afterText.isEmpty, afterText.utf8.count <= 18,
                      afterText.utf8.allSatisfy({ (48...57).contains($0) }),
                      let after = Int64(afterText), after >= 0,
                      let count = limit(args["limit"], default: 8),
                      count <= AndesiteSyncWire.maximumChangesPerBatch else {
                    return .error(400, "invalid_sync_query")
                }
                return VaultHTTPResponse(status: 200, body: try AndesiteSyncWire.encode(
                    backend.syncInboxChanges(sourceVault: source, sourceEpoch: epoch,
                                             after: after, limit: count)))
            }
            if path == "/v1/sync/inbox/snapshots" {
                guard Set(args.keys).isSubset(of: ["source", "epoch", "limit", "offset"]),
                      let source = args["source"], let epoch = args["epoch"],
                      let count = limit(args["limit"]),
                      let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_sync_query")
                }
                return .json(200, try backend.syncInboxSnapshotList(
                    sourceVault: source, sourceEpoch: epoch,
                    limit: count, offset: offset))
            }
            let incoming = path.split(separator: "/", omittingEmptySubsequences: false)
            if incoming.count == 6 && incoming[1] == "v1" &&
               incoming[2] == "sync" && incoming[3] == "inbox" &&
               incoming[4] == "snapshots" {
                guard Set(args.keys) == ["source", "epoch"],
                      let source = args["source"], let epoch = args["epoch"] else {
                    return .error(400, "invalid_sync_query")
                }
                return VaultHTTPResponse(status: 200, body: try AndesiteSyncWire.encode(
                    backend.syncInboxSnapshot(sourceVault: source, sourceEpoch: epoch,
                                              snapshotID: String(incoming[5]))))
            }
            if path == "/v1/sync/inbox" {
                guard Set(args.keys).isSubset(of: ["limit", "offset"]),
                      let count = limit(args["limit"]),
                      let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_sync_query")
                }
                return .json(200, try backend.syncInbox(limit: count, offset: offset))
            }
            if path == "/v1/sync/changes" {
                    let batch = try AndesiteSyncWire.decode(
                        AndesiteSyncChangeBatch.self, bytes: body)
                    let receipt = try backend.receiveSyncChanges(batch)
                    return .json(200, [
                        "sourceVault": receipt.sourceVault,
                        "sourceEpoch": receipt.sourceEpoch,
                         "acknowledgedSequence": receipt.acknowledgedSequence,
                        "accepted": receipt.accepted,
                        "replay": receipt.replay
                    ])
                }
                if path == "/v1/sync/snapshots" {
                    let item = try AndesiteSyncWire.decode(
                        AndesiteSyncSnapshot.self, bytes: body)
                    let inserted = try backend.receiveSyncSnapshot(item)
                    return .json(200, [
                        "sourceVault": item.sourceVault, "sourceEpoch": item.sourceEpoch,
                        "snapshot": item.id, "stored": inserted
                    ])
                }
                return .error(405, "method_not_allowed")
            }
            if method == "PUT" {
                let fields = path.split(separator: "/", omittingEmptySubsequences: false)
                guard fields.count == 5, fields[1] == "v1",
                      fields[2] == "documents", fields[4] == "content",
                      args.isEmpty, let documentID = id(String(fields[3])) else {
                    return .error(405, "method_not_allowed")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                guard let ifMatch, ifMatch.count == 34,
                      ifMatch.hasPrefix("\""), ifMatch.hasSuffix("\""),
                      let expected = id(String(ifMatch.dropFirst().dropLast())) else {
                    return .error(428, "revision_precondition_required")
                }
                let current = try backend.inspectDocument(documentID)
                guard current.revisionID == expected else {
                    return .error(412, "revision_mismatch")
                }
                let updated = try backend.update(current.path, body, revision: expected)
                return .json(200, ["document": hex(updated.id), "revision": hex(updated.revisionID)])
            }
            if path == "/v1/sync/inbox/changes" {
                guard Set(args.keys).isSubset(of: ["source", "epoch", "after", "limit"]),
                      let source = args["source"], let epoch = args["epoch"],
                      let afterText = args["after"],
                      !afterText.isEmpty, afterText.utf8.count <= 18,
                      afterText.utf8.allSatisfy({ (48...57).contains($0) }),
                      let after = Int64(afterText), after >= 0,
                      let count = limit(args["limit"], default: 8),
                      count <= AndesiteSyncWire.maximumChangesPerBatch else {
                    return .error(400, "invalid_sync_query")
                }
                return VaultHTTPResponse(status: 200, body: try AndesiteSyncWire.encode(
                    backend.syncInboxChanges(sourceVault: source, sourceEpoch: epoch,
                                             after: after, limit: count)))
            }
            if path == "/v1/sync/inbox/snapshots" {
                guard Set(args.keys).isSubset(of: ["source", "epoch", "limit", "offset"]),
                      let source = args["source"], let epoch = args["epoch"],
                      let count = limit(args["limit"]),
                      let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_sync_query")
                }
                return .json(200, try backend.syncInboxSnapshotList(
                    sourceVault: source, sourceEpoch: epoch,
                    limit: count, offset: offset))
            }
            let incoming = path.split(separator: "/", omittingEmptySubsequences: false)
            if incoming.count == 6 && incoming[1] == "v1" &&
               incoming[2] == "sync" && incoming[3] == "inbox" &&
               incoming[4] == "snapshots" {
                guard Set(args.keys) == ["source", "epoch"],
                      let source = args["source"], let epoch = args["epoch"] else {
                    return .error(400, "invalid_sync_query")
                }
                return VaultHTTPResponse(status: 200, body: try AndesiteSyncWire.encode(
                    backend.syncInboxSnapshot(sourceVault: source, sourceEpoch: epoch,
                                              snapshotID: String(incoming[5]))))
            }
            if path == "/v1/sync/inbox" {
                guard Set(args.keys).isSubset(of: ["limit", "offset"]),
                      let count = limit(args["limit"]),
                      let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_sync_query")
                }
                return .json(200, try backend.syncInbox(limit: count, offset: offset))
            }
            if path == "/v1/sync/changes" {
                guard Set(args.keys).isSubset(of: ["after", "limit"]),
                      let afterText = args["after"],
                      !afterText.isEmpty, afterText.utf8.count <= 18,
                      afterText.utf8.allSatisfy({ (48...57).contains($0) }),
                      let after = Int64(afterText), after >= 0,
                      let count = limit(args["limit"], default: 8),
                      count <= AndesiteSyncWire.maximumChangesPerBatch else {
                    return .error(400, "invalid_sync_cursor")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                let feed = try backend.syncChanges(after: after, limit: count)
                return VaultHTTPResponse(status: 200,
                                         body: try AndesiteSyncWire.encode(feed))
            }
            let syncPath = path.split(separator: "/",
                                      omittingEmptySubsequences: false)
            if syncPath.count == 5, syncPath[1] == "v1",
               syncPath[2] == "sync", syncPath[3] == "snapshots" {
                guard args.isEmpty,
                      let snapshotID = id(String(syncPath[4])) else {
                    return .error(400, "invalid_sync_snapshot")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                let item = try backend.syncSnapshot(snapshotID)
                return VaultHTTPResponse(status: 200,
                                         body: try AndesiteSyncWire.encode(item))
            }
            if path == "/v1/status" {
                guard args.isEmpty else { return .error(400, "unsupported_parameter") }
                let status = try backend.status()
                return .json(200, [
                    "vault": hex(status.vaultID), "state": status.state,
                    "entries": status.entries, "revisions": status.revisions,
                    "openIncidents": status.openIncidents,
                    "unfinishedMutations": status.unfinishedMutations,
                    "indexedReadable": indexReady && status.state == "ready",
                    "linksIndexed": indexReady && backend.linksIndexed,
                    "linkCacheGeneration": backend.linkCacheGeneration,
                    "linkCacheProgress": backend.linkCacheProgress.map {
                        ["processedHeads": $0.processedHeads,
                         "totalHeads": $0.totalHeads,
                         "resolvedHeads": $0.resolvedHeads] as [String: Int]
                    } as Any? ?? NSNull(),
                    "source": "last_completed_reconciliation"
                ])
            }
            if path == "/v1/search" {
                guard Set(args.keys).isSubset(of: ["q", "limit", "tag", "property", "value"]),
                      let count = limit(args["limit"]) else {
                    return .error(400, "invalid_search")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                let search = try ObsidianSearchQuery.parse(
                    args["q"] ?? "", explicitTag: args["tag"],
                    explicitProperty: args["property"], explicitValue: args["value"])
                let found: [[String: String]]
                if let phrase = search.phrase {
                    found = try backend.searchIndexed(phrase, limit: count,
                                                     filter: search.filter).map {
                        ["document": hex($0.entryID), "revision": hex($0.revisionID),
                         "title": $0.title, "path": $0.path]
                    }
                } else {
                    let page = try backend.documents(limit: count,
                                                     filter: search.filter)
                    found = page.documents.map {
                        ["document": hex($0.id), "revision": hex($0.revisionID),
                         "title": $0.title, "path": $0.path]
                    }
                }
                return .json(200, ["hits": found, "source": "last_completed_reconciliation"])
            }
            if path == "/v1/tags" || path == "/v1/properties" {
                guard Set(args.keys).isSubset(of: ["limit", "offset"]),
                      let count = limit(args["limit"]),
                      let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_metadata_query")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                return .json(200, try path == "/v1/tags" ?
                    backend.tags(limit: count, offset: offset) :
                    backend.properties(limit: count, offset: offset))
            }
            if path == "/v1/documents" {
                guard Set(args.keys).isSubset(of: ["limit", "offset", "tag", "property", "value"]),
                      let count = limit(args["limit"]) else {
                    return .error(400, "invalid_document_query")
                }
                guard let offset = validatedOffset(args["offset"]) else {
                    return .error(400, "invalid_offset")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                let filter = try validatedFilter(args)
                let page = try backend.documents(limit: count, offset: offset,
                                                 filter: filter)
                return .json(200, [
                    "documents": page.documents.map(documentJSON),
                    "total": page.total, "offset": page.offset,
                    "nextOffset": page.nextOffset.map { $0 as Any } ?? NSNull(),
                    "source": "last_completed_reconciliation"
                ])
            }
            let documentPath = path.split(separator: "/", omittingEmptySubsequences: false)
            if documentPath.count >= 4 && documentPath.count <= 5 &&
               documentPath[1] == "v1" && documentPath[2] == "documents" {
                guard let document = id(String(documentPath[3])) else {
                    return .error(400, "invalid_document")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                if documentPath.count == 4 {
                    guard args.isEmpty else { return .error(400, "unsupported_parameter") }
                    return .json(200, try preview(document, of: backend.inspectDocument(document)))
                }
                if documentPath.count == 5 && documentPath[4] == "properties" {
                    guard args.isEmpty else { return .error(400, "unsupported_parameter") }
                    return .json(200, try backend.documentMetadata(document))
                }
                if documentPath.count == 5 &&
                   (documentPath[4] == "links" || documentPath[4] == "backlinks") {
                    guard Set(args.keys).isSubset(of: ["limit", "offset"]),
                          let count = limit(args["limit"]) else {
                        return .error(400, "invalid_link_query")
                    }
                    let offset: Int
                    if let raw = args["offset"] {
                        guard !raw.isEmpty, raw.utf8.count <= 6,
                              raw.utf8.allSatisfy({ (48...57).contains($0) }),
                              let parsed = Int(raw), parsed <= 100_000 else {
                            return .error(400, "invalid_offset")
                        }
                        offset = parsed
                    } else { offset = 0 }
                    let inbound = documentPath[4] == "backlinks"
                    let result = try backend.links(
                        document, direction: inbound ? .incoming : .outgoing,
                        limit: count, offset: offset)
                    return .json(200, [
                        "mentions": result.mentions.map(linkJSON),
                        "total": result.total, "offset": result.offset,
                        "nextOffset": result.nextOffset.map { $0 as Any } ?? NSNull(),
                        "scope": "verified_indexed_markdown_heads_only",
                        "unlinkedMentionsIncluded": false,
                        "source": "last_completed_reconciliation"
                    ])
                }
                if documentPath.count == 5 && documentPath[4] == "content" {
                    guard args.isEmpty else { return .error(400, "unsupported_parameter") }
                    let content = try backend.documentContents(document,
                                                              maximumBytes: maximumResponse)
                    return VaultHTTPResponse(status: 200, body: content,
                                             contentType: "text/markdown; charset=utf-8")
                }
            }
            if path == "/v1/snapshots" {
                guard Set(args.keys).isSubset(of: ["path", "document", "limit", "offset"]),
                      let count = limit(args["limit"]),
                      args["path"] == nil || args["document"] == nil else {
                    return .error(400, "invalid_snapshot_query")
                }
                let document: Data?
                if let value = args["document"] {
                    guard let parsed = id(value) else { return .error(400, "invalid_document") }
                    document = parsed
                } else { document = nil }
                let offset: Int
                if let raw = args["offset"] {
                    guard !raw.isEmpty, raw.utf8.count <= 6,
                          raw.utf8.allSatisfy({ (48...57).contains($0) }),
                          let parsed = Int(raw), parsed <= 100_000 else {
                        return .error(400, "invalid_offset")
                    }
                    offset = parsed
                } else { offset = 0 }
                let snapshots = try backend.snapshots(entryID: document, path: args["path"])
                // A bounded API response; offset paginates newest to oldest
                // without deleting or modifying any earlier snapshot.
                let recent = snapshots.reversed().dropFirst(offset).prefix(count).map(metadata)
                let more = offset + recent.count < snapshots.count
                return .json(200, [
                    "snapshots": recent, "total": snapshots.count, "offset": offset,
                    "nextOffset": more ? offset + recent.count : NSNull(),
                    "truncated": more
                ])
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if components.count == 4 && components[1] == "v1" &&
                components[2] == "snapshots" {
                guard args.isEmpty, let snapshot = id(String(components[3])) else {
                    return .error(400, "invalid_snapshot")
                }
                return .json(200, ["snapshot": metadata(try backend.inspectSnapshot(snapshot))])
            }
            if components.count == 5 && components[1] == "v1" &&
                components[2] == "snapshots" && components[4] == "content" {
                guard args.isEmpty, let snapshot = id(String(components[3])) else {
                    return .error(400, "invalid_snapshot")
                }
                let info = try backend.inspectSnapshot(snapshot)
                guard info.byteLength <= maximumResponse else {
                    return .error(413, "snapshot_too_large_for_local_http")
                }
                return VaultHTTPResponse(status: 200, body: try backend.snapshotContents(snapshot),
                                         contentType: "text/markdown; charset=utf-8")
            }
            return .error(404, "not_found")
        } catch AndesiteSyncError.invalidPacket,
                AndesiteSyncError.invalidPeer,
                AndesiteSyncError.unsupportedVersion {
            return .error(400, "invalid_sync_packet")
        } catch AndesiteSyncError.historyGap,
                AndesiteSyncError.sequenceConflict,
                AndesiteSyncError.contentMismatch {
            return .error(409, "sync_conflict_or_corrupt_payload")
        } catch AndesiteSyncError.artifactTooLarge {
            return .error(413, "sync_artifact_exceeds_inline_limit")
        } catch VaultLinkGraphError.invalidQuery {
            return .error(400, "invalid_link_query")
        } catch VaultLinkGraphError.graphTooLarge {
            return .error(413, "link_graph_exceeds_safety_budget")
        } catch VaultLinkGraphError.cacheNotReady {
            return .error(503, "link_index_pending")
        } catch VaultLinkGraphError.inconsistentCatalog {
            return .error(503, "link_graph_inconsistent")
        } catch MarkdownAnalysisError.invalidUTF8 {
            return .error(422, "invalid_markdown_utf8")
        } catch VaultError.conflict {
            return .error(409, "edit_conflict_or_unsafe_target")
        } catch ObsidianIndexError.invalidQuery {
            return .error(400, "invalid_metadata_query")
        } catch ObsidianIndexError.inconsistentIndex {
            return .error(503, "metadata_index_inconsistent")
        } catch DocumentCatalogError.notFound {
            return .error(404, "document_not_found")
        } catch DocumentCatalogError.contentTooLarge {
            return .error(413, "document_too_large_for_local_http")
        } catch DocumentCatalogError.invalidIdentifier, DocumentCatalogError.invalidPage {
            return .error(400, "invalid_document")
        } catch DocumentCatalogError.inconsistentMetadata {
            return .error(503, "document_catalog_inconsistent")
        } catch SnapshotError.notFound {
            return .error(404, "snapshot_not_found")
        } catch SearchIndexError.invalidQuery {
            return .error(400, "invalid_search")
        } catch VaultRuntimeError.inconsistentCatalog {
            return .error(503, "index_not_ready")
        } catch {
            // Detailed internal paths/SQLite failures must not leak to clients.
            return .error(503, "read_unavailable")
        }
    }
}
#endif
