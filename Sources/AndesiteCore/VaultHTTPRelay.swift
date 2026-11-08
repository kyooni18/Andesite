#if os(macOS)
import Foundation
import CAndesiteFS

public struct VaultRelayResult: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public init(status: Int, contentType: String, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

/// Prevents concurrent requests from competing with the single-threaded
/// watcher. Blocking AF_UNIX I/O runs on a background queue, never on an
/// Hummingbird/NIO event-loop thread. Only a version-conditioned Markdown
/// PUT is authorized in addition to the existing read-only GET routes.
public actor VaultHTTPRelay {
    private let socketPath: String
    private var busy = false
    public init(socketPath: String) { self.socketPath = socketPath }

    public func get(_ target: String) async -> VaultRelayResult {
        // Check UTF-8 bytes, not Swift grapheme clusters: CRLF can be a
        // single Character, so String.contains("\r") may miss it.
        guard target.utf8.count <= 4096,
              !target.utf8.contains(13), !target.utf8.contains(10),
              !target.utf8.contains(0), !target.utf8.contains(92),
              target.hasPrefix("/v1/") else {
            return Self.error(400, "invalid_target")
        }
        guard !busy else { return Self.error(503, "backend_busy") }
        busy = true
        defer { busy = false }
        let path = socketPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.read(path: path, target: target))
            }
        }
    }

    public func put(_ target: String, expectedRevision: String,
                    contents: Data) async -> VaultRelayResult {
        guard target.hasPrefix("/v1/documents/"), target.hasSuffix("/content"),
              target.utf8.count <= 100, !target.utf8.contains(13),
              !target.utf8.contains(10), !target.utf8.contains(92),
              !target.utf8.contains(0),
              expectedRevision.utf8.count == 32,
              expectedRevision.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0) ||
                  (65...70).contains($0)
              }),
              contents.count <= 256 * 1024 else {
            return Self.error(400, "invalid_edit_request")
        }
        guard !busy else { return Self.error(503, "backend_busy") }
        busy = true
        defer { busy = false }
        let path = socketPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.sendEdit(
                    path: path, target: target,
                    expectedRevision: expectedRevision, contents: contents))
            }
        }
    }

    nonisolated private static func error(_ status: Int, _ code: String) -> VaultRelayResult {
        VaultRelayResult(status: status, contentType: "application/json; charset=utf-8",
                         body: Data("{\"error\":\"\(code)\"}".utf8))
    }

    nonisolated private static func sendEdit(path: String, target: String,
                                             expectedRevision: String,
                                             contents: Data) -> VaultRelayResult {
        let maximum = 1_100_000
        var response = [UInt8](repeating: 0, count: maximum)
        var length: UInt = 0
        let ok = response.withUnsafeMutableBufferPointer { output in
            path.withCString { address in
                target.withCString { uri in
                    expectedRevision.withCString { revision in
                        contents.withUnsafeBytes { raw in
                            andesite_http_relay_put(
                                address, uri, revision,
                                raw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(contents.count), output.baseAddress,
                                UInt(maximum), &length)
                        }
                    }
                }
            }
        }
        guard ok == 0, length > 0, length <= maximum else {
            return error(503, "vault_watcher_unavailable")
        }
        return decodeResponse(Data(response.prefix(Int(length))))
    }

    nonisolated private static func read(path: String, target: String) -> VaultRelayResult {
        let maximum = 1_100_000
        var response = [UInt8](repeating: 0, count: maximum)
        var length: UInt = 0
        let ok = response.withUnsafeMutableBufferPointer { bytes in
            path.withCString { address in
                target.withCString { uri in
                    andesite_http_relay_get(address, uri, bytes.baseAddress, UInt(maximum), &length)
                }
            }
        }
        guard ok == 0, length > 0, length <= maximum else {
            return error(503, "vault_watcher_unavailable")
        }
        return decodeResponse(Data(response.prefix(Int(length))))
    }

    nonisolated private static func decodeResponse(_ data: Data) -> VaultRelayResult {
        let delimiter = Data([13, 10, 13, 10])
        guard let end = data.range(of: delimiter), end.lowerBound <= 8192,
              let headerText = String(data: data.prefix(upTo: end.lowerBound), encoding: .utf8) else {
            return error(503, "invalid_backend_response")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return error(503, "invalid_backend_response") }
        let tokens = statusLine.split(separator: " ")
        guard tokens.count >= 2, tokens[0] == "HTTP/1.1",
              let status = Int(tokens[1]), (200...599).contains(status) else {
            return error(503, "invalid_backend_response")
        }
        var expectedLength: Int?
        var type: String?
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return error(503, "invalid_backend_response") }
            let key = pieces[0].lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                guard expectedLength == nil, let n = Int(value), n >= 0, n <= 1_048_576 else {
                    return error(503, "invalid_backend_response")
                }
                expectedLength = n
            }
            if key == "content-type" {
                guard type == nil,
                      value == "application/json; charset=utf-8" ||
                      value == "text/markdown; charset=utf-8" else {
                    return error(503, "invalid_backend_response")
                }
                type = value
            }
        }
        let content = Data(data.suffix(from: end.upperBound))
        guard content.count == expectedLength, let type else {
            return error(503, "invalid_backend_response")
        }
        return VaultRelayResult(status: status, contentType: type, body: content)
    }
}
#endif
