import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SyncTransportError: Error, Equatable {
    case insecureDestination
    case invalidCredential
    case invalidResponse
    case rejected(Int, String)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the token or note contents to another endpoint.
        completionHandler(nil)
    }
}

/// Syncs a local Vault with one served by `andesite-server serve`.
///
/// Network I/O runs off the session's owner queue; every backend step is a
/// short `perform` job. Progress is durable after each step (pull cursor,
/// push acknowledgement, recorded revisions), so an interrupted sync simply
/// resumes on the next call. Plain HTTP is accepted only for loopback.
public final class SyncClient: Sendable {
    private let endpoint: URL
    private let token: String
    private let http: URLSession

    public init(destination: URL, token: String) throws {
        let host = destination.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard destination.scheme == "https" || (destination.scheme == "http" && loopback), !host.isEmpty,
              destination.user == nil, destination.password == nil, destination.query == nil, destination.fragment == nil,
              destination.path.isEmpty || destination.path == "/" else { throw SyncTransportError.insecureDestination }
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw SyncTransportError.invalidCredential
        }
        endpoint = destination
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        http = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// One complete exchange: pull the peer's new revisions and resolve
    /// them locally, then push local revisions for the peer to resolve.
    public func sync(_ session: VaultSession) async throws -> SyncReport {
        try await session.perform { _ = try $0.reconcile() }
        let peer: SyncIdentity = try decode(await request("GET", "/v1/sync/identity"))

        var report = SyncReport()
        var cursor = try await session.perform { try $0.syncCursor(peer) }
        while true {
            let batch: SyncBatch = try decode(await request("GET", "/v1/sync/changes?after=\(cursor)&limit=\(VaultRuntime.syncPageLimit)"))
            guard batch.vault == peer.vault, batch.epoch == peer.epoch, batch.through >= cursor else { throw SyncTransportError.invalidResponse }
            let hashes = Array(Set(batch.records.compactMap(\.hash)))
            for hash in try await session.perform({ try $0.missingObjects(hashes) }) {
                let content = try await request("GET", "/v1/sync/objects/" + hash)
                try await session.perform { try $0.storeObject(content, hash: hash) }
            }
            report.received += try await session.perform { try $0.receive(batch) }
            cursor = batch.through
            if cursor >= batch.head { break }
        }
        report.add(try await session.perform { try $0.resolvePending() })

        var acknowledged = try await session.perform { try $0.acknowledgedSequence(peer) }
        while true {
            let after = acknowledged
            let batch = try await session.perform { try $0.syncFeed(after: after) }
            if !batch.records.isEmpty {
                let hashes = Array(Set(batch.records.compactMap(\.hash))).sorted()
                let missing: [String] = try decode(await request("POST", "/v1/sync/objects/missing", body: try JSONEncoder().encode(hashes)))
                for hash in missing where hashes.contains(hash) {
                    let content = try await session.perform { try $0.object(hash) }
                    _ = try await request("PUT", "/v1/sync/objects/" + hash, body: content)
                }
                let remote: SyncReport = try decode(await request("POST", "/v1/sync/changes", body: try JSONEncoder().encode(batch)))
                report.sent += remote.received
            }
            try await session.perform { try $0.acknowledge(peer, through: batch.through) }
            acknowledged = batch.through
            if acknowledged >= batch.head { break }
        }
        return report
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncTransportError.invalidResponse }
        guard response.statusCode == 200 else {
            throw SyncTransportError.rejected(response.statusCode, String(decoding: data.prefix(512), as: UTF8.self))
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SyncTransportError.invalidResponse }
    }
}
