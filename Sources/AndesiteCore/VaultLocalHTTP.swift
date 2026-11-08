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
        return VaultHTTPResponse(status: status, body: bytes)
    }

    static func error(_ status: Int, _ code: String) -> VaultHTTPResponse {
        json(status, ["error": code])
    }
}

/// GET-only HTTP/1.1 over a private Unix domain socket in the already
/// validated 0700 state directory. The OS verifies same-UID peer credentials.
/// No TCP listener, extra database connection, executor, or background thread.
public final class VaultLocalHTTP {
    private let runtime: VaultRuntime
    private let server: OpaquePointer
    public static let socketName = "andesite-read.sock"
    private let maximumHeaders = 8192
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
        self.runtime = runtime
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

        var request = [CChar](repeating: 0, count: maximumHeaders)
        let length = request.withUnsafeMutableBufferPointer {
            andesite_local_http_read_headers(client, $0.baseAddress, UInt($0.count))
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
            405: "Method Not Allowed", 413: "Content Too Large",
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

    /// Internal pure request decoding, with runtime access restricted to the
    /// synchronous watcher owner. Does not read current source files.
    func handle(request: Data, indexReady: Bool) -> VaultHTTPResponse {
        guard request.count <= maximumHeaders,
              let raw = String(data: request, encoding: .utf8),
              raw.hasSuffix("\r\n\r\n"),
              !raw.contains("\0") else { return .error(400, "invalid_request") }

        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .error(400, "invalid_request") }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1",
              first.utf8.count <= 4096 else { return .error(400, "invalid_request") }
        guard words[0] == "GET" else { return .error(405, "read_only") }

        var hostCount = 0
        for header in lines.dropFirst().dropLast(2) {
            guard let separator = header.firstIndex(of: ":"), header.first != " ",
                  header.first != "\t" else { return .error(400, "invalid_headers") }
            let name = header[..<separator]
            guard !name.isEmpty, name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45
            }) else { return .error(400, "invalid_headers") }
            switch name.lowercased() {
            case "host": hostCount += 1
            case "content-length", "transfer-encoding", "expect", "upgrade":
                return .error(400, "request_body_not_supported")
            default: break
            }
        }
        guard hostCount == 1 else { return .error(400, "invalid_headers") }

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
            if path == "/v1/status" {
                guard args.isEmpty else { return .error(400, "unsupported_parameter") }
                let status = try runtime.status()
                return .json(200, [
                    "vault": hex(status.vaultID), "state": status.state,
                    "entries": status.entries, "revisions": status.revisions,
                    "openIncidents": status.openIncidents,
                    "unfinishedMutations": status.unfinishedMutations,
                    "indexedReadable": indexReady && status.state == "ready",
                    "source": "last_completed_reconciliation"
                ])
            }
            if path == "/v1/search" {
                guard Set(args.keys).isSubset(of: ["q", "limit"]),
                      let phrase = args["q"], let count = limit(args["limit"]),
                      !phrase.isEmpty, phrase.utf8.count <= 1024 else {
                    return .error(400, "invalid_search")
                }
                guard indexReady else { return .error(503, "rescan_pending") }
                let found = try runtime.searchIndexed(phrase, limit: count).map {
                    ["document": hex($0.entryID), "revision": hex($0.revisionID), "title": $0.title]
                }
                return .json(200, ["hits": found, "source": "last_completed_reconciliation"])
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
                let snapshots = try runtime.snapshots(entryID: document, path: args["path"])
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
                return .json(200, ["snapshot": metadata(try runtime.inspectSnapshot(snapshot))])
            }
            if components.count == 5 && components[1] == "v1" &&
                components[2] == "snapshots" && components[4] == "content" {
                guard args.isEmpty, let snapshot = id(String(components[3])) else {
                    return .error(400, "invalid_snapshot")
                }
                let info = try runtime.inspectSnapshot(snapshot)
                guard info.byteLength <= maximumResponse else {
                    return .error(413, "snapshot_too_large_for_local_http")
                }
                return VaultHTTPResponse(status: 200, body: try runtime.snapshotContents(snapshot),
                                         contentType: "text/markdown; charset=utf-8")
            }
            return .error(404, "not_found")
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
