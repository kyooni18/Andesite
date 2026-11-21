import Foundation
import AndesiteCore
import Hummingbird

/// Every folder directly inside `root` is a vault, named by the folder.
/// A vault is opened, and starts being watched, the first time a request
/// needs it, so a large library costs nothing until it is used. Each keeps
/// its server state in `stateRoot/<name>`.
public actor VaultLibrary {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
    }

    private let root: URL
    private let stateRoot: URL
    private let report: @Sendable (String) -> Void
    private var open: [String: Vault] = [:]

    public init(root: String, stateRoot: String, report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = URL(fileURLWithPath: root, isDirectory: true)
        self.stateRoot = URL(fileURLWithPath: stateRoot, isDirectory: true)
        self.report = report
    }

    /// The vault folders, by name; hidden folders are not vaults.
    public func list() throws -> [Entry] {
        try folders().keys.sorted().map { Entry(name: $0) }
    }

    /// The vault called `name`, opening it if needed.
    public func vault(_ name: String) throws -> Vault {
        let key = try Self.validName(name)
        if let vault = open[key] { return vault }
        guard let folder = try folders()[key] else { throw APIError(.notFound, "vault_not_found") }
        let state = stateRoot.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let vault = try Vault(at: root.appendingPathComponent(folder).path,
                              options: .init(stateDirectory: state.path, watch: false))
        try vault.startWatching(report: { [report] in report("\(key): \($0)") })
        open[key] = vault
        report("vault-open name=\(key)")
        return vault
    }

    /// Makes an empty vault called `name`.
    public func create(_ name: String) throws -> Entry {
        let key = try Self.validName(name)
        guard try folders()[key] == nil else { throw APIError(.conflict, "vault_exists") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(key, isDirectory: true),
                                                withIntermediateDirectories: false)
        _ = try vault(key)
        return Entry(name: key)
    }

    public func close() {
        for vault in open.values { try? vault.close() }
        open.removeAll()
    }

    /// Folder names keyed by their composed (NFC) form, so a name typed on
    /// another device finds a folder whose name the disk stores decomposed.
    private func folders() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where !name.hasPrefix(".") {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            result[name.precomposedStringWithCanonicalMapping] = name
        }
        return result
    }

    static func validName(_ name: String) throws -> String {
        let name = name.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw APIError(.badRequest, "invalid_vault_name")
        }
        return name
    }
}

extension AndesiteHTTPServer {
    /// Serves every vault in `library` at `/v1/vaults/<name>/…` (the
    /// document and index API) and `/sync/vaults/<name>/…` (the sync API),
    /// with `/v1/…` and `/sync/…` meaning the vault `main`.
    /// `GET /sync/vaults` and `GET /v1/vaults` list them; `POST /sync/vaults
    /// {"name"}` adds one.
    public static func run(library: VaultLibrary, token: String, port: Int,
                           sessionLifetime: TimeInterval = SessionStore.defaultLifetime,
                           onReady: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        guard isValidToken(token) else { throw APIError(.badRequest, "invalid_token") }
        let app = Application(router: router(library: library, token: token, sessions: SessionStore(lifetime: sessionLifetime)),
                              configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "Andesite"),
                              onServerRunning: { onReady($0.localAddress?.port ?? port) })
        try await app.runService()
    }

    static func router(library: VaultLibrary, token: String, sessions: SessionStore = SessionStore()) -> Router<BasicRequestContext> {
        let router = Router()
        router.middlewares.add(Authentication(token: Array(token.utf8), sessions: sessions))
        addSessionRoutes(router, token: Array(token.utf8), sessions: sessions)
        router.get("/sync/vaults") { _, _ in
            await respond { try encoded(["vaults": try await library.list()]) }
        }
        // The same list under /v1, which browser sessions can reach.
        router.get("/v1/vaults") { _, _ in
            await respond { try encoded(["vaults": try await library.list()]) }
        }
        router.post("/sync/vaults") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 64 * 1024))
            return await respond {
                guard let name = (try? JSONDecoder().decode([String: String].self, from: body))?["name"] else {
                    throw APIError(.badRequest, "invalid_json")
                }
                var reply = try encoded(try await library.create(name))
                reply.status = 201
                return reply
            }
        }
        let named: VaultResolver = { _, context in
            let name = context.parameters.get("vault") ?? ""
            return try await library.vault(name.removingPercentEncoding ?? name)
        }
        addVaultRoutes(router, at: "/v1/vaults/{vault}", vault: named)
        addVaultRoutes(router, at: "/v1") { _, _ in try await library.vault("main") }
        addSyncRoutes(router, at: "/sync/vaults/{vault}", vault: named)
        addSyncRoutes(router, at: "/sync") { _, _ in try await library.vault("main") }
        return router
    }
}
