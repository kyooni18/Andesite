import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AndesiteSyncTransportError: Error, Equatable {
    case insecureDestination
    case invalidCredential
    case invalidResponse
    case rejected(Int)
}

private final class AndesiteNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward sync authorization or note contents to an unexpected
        // endpoint, even if a reverse proxy sends a redirect.
        completionHandler(nil)
    }
}

/// HTTP transport for an embedded app or command-line sync worker. Prepare
/// payloads on the backend owner, await the network off that executor, then
/// acknowledge on the original owner only after a matching verified receipt.
/// This transport never touches SQLite, FSEvents or source Markdown files.
public final class AndesiteHTTPSyncClient: @unchecked Sendable {
    private let endpoint: URL
    private let token: String
    private let session: URLSession

    public init(destination: URL, token: String) throws {
        let host = destination.host?.lowercased() ?? ""
        let loopback = host == "localhost" || host == "127.0.0.1" ||
                       host == "::1" || host == "[::1]"
        guard destination.scheme == "https" ||
              (destination.scheme == "http" && loopback),
              !host.isEmpty, destination.user == nil,
              destination.password == nil, destination.query == nil,
              destination.fragment == nil,
              destination.path.isEmpty || destination.path == "/" else {
            throw AndesiteSyncTransportError.insecureDestination
        }
        guard token.utf8.count == 64, token.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0) ||
            (65...70).contains($0)
        }) else { throw AndesiteSyncTransportError.invalidCredential }
        endpoint = destination
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration,
                             delegate: AndesiteNoRedirects(),
                             delegateQueue: nil)
    }

    /// A human peer label alone is not a safe replay checkpoint: the same
    /// label used with another destination could otherwise skip history.
    /// Bind the cursor to the normalized TLS/loopback destination identity.
    public func checkpointKey(peer: String) throws -> String {
        guard !peer.isEmpty, peer.utf8.count <= 96,
              !peer.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else { throw AndesiteSyncError.invalidPeer }
        let canonical = endpoint.scheme!.lowercased() + "://" +
                        endpoint.host!.lowercased() + ":" +
                        String(endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80))
        return peer + "@" + canonical
    }

    private func send<T: Encodable>(_ value: T, to path: String) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try AndesiteSyncWire.encode(value)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard data.count <= AndesiteSyncWire.maximumJSONBytes,
              let response = response as? HTTPURLResponse else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw AndesiteSyncTransportError.rejected(response.statusCode)
        }
        return data
    }

    private func fetch(path: String, query: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(
            url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw AndesiteSyncTransportError.invalidResponse }
        components.queryItems = query
        guard let target = components.url else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard data.count <= AndesiteSyncWire.maximumJSONBytes,
              let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        guard status == 200 else { throw AndesiteSyncTransportError.rejected(status) }
        return data
    }

    /// Retrieve remote archived revisions without applying them to the
    /// local files. A higher-level reconciler must resolve conflicting heads.
    public func downloadIncomingChanges(sourceVault: String, sourceEpoch: String,
                                        after: Int64, limit: Int = 8) async throws
        -> AndesiteSyncChangeBatch {
        let json = try await fetch(path: "v1/sync/inbox/changes", query: [
            .init(name: "source", value: sourceVault),
            .init(name: "epoch", value: sourceEpoch),
            .init(name: "after", value: String(after)),
            .init(name: "limit", value: String(limit))
        ])
        let packet = try AndesiteSyncWire.decode(AndesiteSyncChangeBatch.self,
                                                 bytes: json)
        guard packet.protocolVersion == 1,
              packet.sourceVault == sourceVault,
              packet.sourceEpoch == sourceEpoch,
              packet.after == after,
              packet.changes.count <= AndesiteSyncWire.maximumChangesPerBatch,
              packet.through <= packet.headSequence else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        for (index, item) in packet.changes.enumerated() {
            guard item.sequence == after + Int64(index) + 1 else {
                throw AndesiteSyncTransportError.invalidResponse
            }
            _ = try AndesiteSyncWire.validateEvent(item)
        }
        return packet
    }

    public func downloadIncomingSnapshot(sourceVault: String, sourceEpoch: String,
                                         id: String) async throws
        -> AndesiteSyncSnapshot {
        guard AndesiteSyncWire.identifier(id, bytes: 16) != nil else {
            throw AndesiteSyncError.invalidPacket
        }
        let json = try await fetch(path: "v1/sync/inbox/snapshots/" + id,
                                   query: [
                                    .init(name: "source", value: sourceVault),
                                    .init(name: "epoch", value: sourceEpoch)
                                   ])
        let snapshot = try AndesiteSyncWire.decode(
            AndesiteSyncSnapshot.self, bytes: json)
        guard snapshot.sourceVault == sourceVault,
              snapshot.sourceEpoch == sourceEpoch,
              snapshot.id == id else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        _ = try AndesiteSyncWire.validateSnapshot(snapshot)
        return snapshot
    }

    public func uploadChanges(_ batch: AndesiteSyncChangeBatch) async throws
        -> AndesiteSyncReceipt {
        let response = try await send(batch, to: "v1/sync/changes")
        let receipt = try AndesiteSyncWire.decode(
            AndesiteSyncReceipt.self, bytes: response)
        guard receipt.sourceVault == batch.sourceVault,
              receipt.sourceEpoch == batch.sourceEpoch,
              receipt.acknowledgedSequence == batch.through else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        return receipt
    }

    public func uploadSnapshot(_ snapshot: AndesiteSyncSnapshot) async throws -> Bool {
        let response = try await send(snapshot, to: "v1/sync/snapshots")
        guard let values = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              values["sourceVault"] as? String == snapshot.sourceVault,
              values["sourceEpoch"] as? String == snapshot.sourceEpoch,
              values["snapshot"] as? String == snapshot.id,
              let stored = values["stored"] as? Bool else {
            throw AndesiteSyncTransportError.invalidResponse
        }
        return stored
    }
}
