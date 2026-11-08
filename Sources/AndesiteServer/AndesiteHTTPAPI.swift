#if os(macOS)
import Foundation
import AndesiteCore
import Hummingbird

@available(macOS 14.0, *)
private struct AndesiteBearerAuthorization: RouterMiddleware {
    typealias Context = BasicRequestContext

    let expectedToken: [UInt8]

    private func authorized(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("Bearer ") else { return false }
        let proposed = Array(value.dropFirst(7).utf8)
        // Require the entire token, then compare all bytes without
        // short-circuiting on individual positions.
        guard proposed.count == expectedToken.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<expectedToken.count {
            difference |= proposed[index] ^ expectedToken[index]
        }
        return difference == 0
    }

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        guard authorized(request.headers[.authorization]) else {
            return Self.failure(.unauthorized, "authentication_required")
        }
        guard request.method == .get else {
            return Self.failure(.methodNotAllowed, "read_only")
        }
        guard request.headers[.contentLength] == nil,
              request.headers[.transferEncoding] == nil,
              request.headers[.upgrade] == nil else {
            return Self.failure(.badRequest, "request_body_not_supported")
        }
        return try await next(request, context)
    }

    static func failure(_ status: HTTPResponse.Status, _ message: String) -> Response {
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        return Response(
            status: status,
            headers: [
                .contentType: "application/json; charset=utf-8",
                .cacheControl: "no-store",
                .init("x-content-type-options")!: "nosniff"
            ],
            body: .init(byteBuffer: ByteBuffer(bytes: body))
        )
    }
}

@available(macOS 14.0, *)
enum AndesiteHTTPAPI {
    enum ConfigurationError: Error {
        case invalidPort
        case missingToken
        case invalidToken
        case watcherNotRunning
    }

    private static func forward(_ request: Request, via relay: VaultHTTPRelay) async -> Response {
        let target = request.uri.path + (request.uri.query.map { "?" + $0 } ?? "")
        let result = await relay.get(target)
        return Response(
            status: HTTPResponse.Status(code: result.status),
            headers: [
                .contentType: result.contentType,
                .cacheControl: "no-store",
                .init("x-content-type-options")!: "nosniff"
            ],
            body: .init(byteBuffer: ByteBuffer(bytes: result.body))
        )
    }

    static func run(vault: String, state: String?, port: Int) async throws {
        guard (1024...65535).contains(port) else { throw ConfigurationError.invalidPort }
        guard let rawToken = ProcessInfo.processInfo.environment["ANDESITE_API_TOKEN"] else {
            throw ConfigurationError.missingToken
        }
        // Requiring 32 bytes from a hex-encoded random token strongly
        // discourages accidental deployment with a guessable password.
        guard rawToken.utf8.count == 64,
              rawToken.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0) ||
                  (65...70).contains($0)
              }) else { throw ConfigurationError.invalidToken }

        let stateDirectory = try state ?? VaultSession.plannedStateDirectory(vaultDirectory: vault)
        let socketPath = try VaultLocalHTTP.socketPath(for: stateDirectory)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ConfigurationError.watcherNotRunning
        }
        let relay = VaultHTTPRelay(socketPath: socketPath)
        let startup = await relay.get("/v1/status")
        guard startup.status == 200 else { throw ConfigurationError.watcherNotRunning }
        let router = Router(context: BasicRequestContext.self)
        router.middlewares.add(AndesiteBearerAuthorization(expectedToken: Array(rawToken.utf8)))

        router.get("/v1/status") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/search") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/documents") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/documents/{id}") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/documents/{id}/content") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/snapshots") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/snapshots/{id}") { request, _ in await Self.forward(request, via: relay) }
        router.get("/v1/snapshots/{id}/content") { request, _ in await Self.forward(request, via: relay) }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "Andesite",
                backlog: 32
            ),
            onServerRunning: { _ in
                FileHandle.standardOutput.write(
                    Data("api-ready host=127.0.0.1 port=\(port) transport=http1 authentication=bearer readOnly=true\n".utf8)
                )
            }
        )
        try await app.run()
    }
}
#endif
