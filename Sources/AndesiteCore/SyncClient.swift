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
/// Network I/O runs off the vault's thread; every backend step is a
/// short background job. Progress is durable after each step (pull cursor,
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
    public func sync(_ vault: Vault) async throws -> SyncReport {
        try await vault.refresh()
        let peer: SyncIdentity = try decode(await request("GET", "/sync/identity"))

        var report = SyncReport()
        var cursor = try await vault.perform(.background) { try $0.syncCursor(peer) }
        while true {
            let batch: SyncBatch = try decode(await request("GET", "/sync/changes?after=\(cursor)&limit=\(VaultRuntime.syncPageLimit)"))
            guard batch.vault == peer.vault, batch.epoch == peer.epoch, batch.through >= cursor else { throw SyncTransportError.invalidResponse }
            try await download(batch.records, into: vault)
            report.received += try await vault.perform(.background) { try $0.receive(batch) }
            cursor = batch.through
            if cursor >= batch.head { break }
        }
        report.add(try await vault.perform(.background) { try $0.resolvePending() })

        var acknowledged = try await vault.perform(.background) { try $0.acknowledgedSequence(peer) }
        while true {
            let after = acknowledged
            let batch = try await vault.perform(.background) { try $0.syncFeed(after: after) }
            if !batch.records.isEmpty {
                try await upload(batch.records, from: vault)
                let remote: SyncReport = try decode(await request("POST", "/sync/changes", body: try JSONEncoder().encode(batch)))
                report.sent += remote.received
            }
            try await vault.perform(.background) { try $0.acknowledge(peer, through: batch.through) }
            acknowledged = batch.through
            if acknowledged >= batch.head { break }
        }
        return report
    }

    /// Waits up to `seconds` (at most 55) for the server to record changes
    /// this Vault has not pulled yet, and says whether there are any. A
    /// sync loop calls this between syncs so other devices' edits arrive
    /// at once, with one idle request open instead of frequent polling.
    public func waitForChanges(_ vault: Vault, seconds: Int = 25) async throws -> Bool {
        let peer: SyncIdentity = try decode(await request("GET", "/sync/identity"))
        let cursor = try await vault.perform(.background) { try $0.syncCursor(peer) }
        let batch: SyncBatch = try decode(await request("GET", "/sync/changes?after=\(cursor)&limit=1&wait=\(seconds)",
                                                        timeout: TimeInterval(seconds + 30)))
        guard batch.vault == peer.vault, batch.epoch == peer.epoch else { throw SyncTransportError.invalidResponse }
        return batch.head > cursor
    }

    /// Requests in flight at once while transferring objects.
    private static let parallelTransfers = 4

    /// Fetches the content the records need, resuming partial transfers.
    /// Small objects come many to a request; large ones in chunks.
    private func download(_ records: [SyncRecord], into vault: Vault) async throws {
        let sizes = Self.sizes(records)
        let missing = try await vault.perform(.background, { [hashes = Array(sizes.keys)] in try $0.missingObjects(hashes) })
        let (small, large) = Self.split(missing, sizes)
        try await forEachConcurrently(Self.bundles(small, sizes)) { hashes in
            let bundle = try await self.request("POST", "/sync/objects/fetch", body: try JSONEncoder().encode(hashes))
            let stored = try await vault.perform(.background) { try $0.receiveBundle(bundle) }
            guard stored == hashes.count else { throw SyncTransportError.invalidResponse }
        }
        try await forEachConcurrently(large) { item in
            let size = sizes[item.hash] ?? 0
            var offset = item.received
            repeat {
                let at = offset, length = Int(min(Int64(VaultRuntime.chunkLimit), size - at))
                let data = try await self.request("GET", "/sync/objects/\(item.hash)?offset=\(at)&length=\(length)")
                guard data.count == length else { throw SyncTransportError.invalidResponse }
                offset = try await vault.perform(.background) { try $0.receiveChunk(item.hash, size: size, offset: at, data) }
                guard offset > at || size == 0 else { throw SyncTransportError.invalidResponse }
            } while offset < size
        }
    }

    /// Sends the content the peer lacks, resuming partial transfers.
    private func upload(_ records: [SyncRecord], from vault: Vault) async throws {
        let sizes = Self.sizes(records)
        let missing: [ObjectProgress] = try decode(await request("POST", "/sync/objects/missing",
                                                                 body: try JSONEncoder().encode(sizes.keys.sorted())))
        let (small, large) = Self.split(missing.filter { sizes[$0.hash] != nil }, sizes)
        try await forEachConcurrently(Self.bundles(small, sizes)) { hashes in
            let bundle = try await vault.perform(.background) { try $0.objectBundle(hashes) }
            let reply = try await self.request("POST", "/sync/objects/bundle", body: bundle)
            guard (try? JSONSerialization.jsonObject(with: reply) as? [String: Int])?["received"] == hashes.count else {
                throw SyncTransportError.invalidResponse
            }
        }
        try await forEachConcurrently(large) { item in
            let size = sizes[item.hash] ?? 0
            var offset = item.received
            repeat {
                let at = offset, length = Int(min(Int64(VaultRuntime.chunkLimit), size - at))
                let data = try await vault.perform(.background) { try $0.objectChunk(item.hash, offset: at, length: length) }
                let reply: ObjectProgress = try self.decode(await self.request(
                    "PUT", "/sync/objects/\(item.hash)?size=\(size)&offset=\(at)", body: data,
                    headers: ["X-Chunk-SHA256": ObjectStore.hash(data)]))
                offset = reply.received
                guard offset > at || size == 0 else { throw SyncTransportError.invalidResponse }
            } while offset < size
        }
    }

    private static func sizes(_ records: [SyncRecord]) -> [String: Int64] {
        Dictionary(records.compactMap { r in r.hash.map { ($0, r.size ?? 0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Whole small objects not yet started go in bundles; the rest in chunks.
    private static func split(_ missing: [ObjectProgress], _ sizes: [String: Int64]) -> (small: [String], large: [ObjectProgress]) {
        var small: [String] = [], large: [ObjectProgress] = []
        for item in missing {
            if item.received == 0, let size = sizes[item.hash], size <= VaultRuntime.bundledObjectLimit {
                small.append(item.hash)
            } else {
                large.append(item)
            }
        }
        return (small, large)
    }

    /// Groups hashes so each bundle stays within `chunkLimit`.
    private static func bundles(_ hashes: [String], _ sizes: [String: Int64]) -> [[String]] {
        var groups: [[String]] = [], current: [String] = [], bytes = 0
        for hash in hashes {
            let cost = ObjectBundle.frameOverhead + Int(sizes[hash] ?? 0)
            if !current.isEmpty && bytes + cost > VaultRuntime.chunkLimit { groups.append(current); current = []; bytes = 0 }
            current.append(hash); bytes += cost
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func forEachConcurrently<T: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = items.makeIterator(), running = 0
            while running < Self.parallelTransfers, let item = next.next() { group.addTask { try await body(item) }; running += 1 }
            while try await group.next() != nil {
                if let item = next.next() { group.addTask { try await body(item) } }
            }
        }
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                         timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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
