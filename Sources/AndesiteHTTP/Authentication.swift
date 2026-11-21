import Foundation
import Hummingbird

/// Browser sessions: a random ID held in memory with an expiry. The
/// browser keeps the ID in an `HttpOnly` cookie, so page scripts never see
/// the long-lived API token. Sessions end when the server restarts.
public final class SessionStore: @unchecked Sendable {
    public static let defaultLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// The most sessions kept at once; the oldest go first.
    static let capacity = 256

    public let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var expiries: [String: Date] = [:]
    private var order: [String] = []   // oldest first

    public init(lifetime: TimeInterval = SessionStore.defaultLifetime, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.now = now
    }

    /// Starts a session and returns its ID.
    func create() -> String {
        var generator = SystemRandomNumberGenerator()
        let id = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        lock.withLock {
            let current = now()
            order.removeAll { id in !(expiries[id].map { $0 > current } ?? false) }
            expiries = expiries.filter { $0.value > current }
            while order.count >= Self.capacity { expiries[order.removeFirst()] = nil }
            expiries[id] = current.addingTimeInterval(lifetime)
            order.append(id)
        }
        return id
    }

    func isValid(_ id: String) -> Bool {
        lock.withLock {
            guard let expiry = expiries[id] else { return false }
            if expiry > now() { return true }
            expiries[id] = nil
            return false
        }
    }

    func revoke(_ id: String) { lock.withLock { expiries[id] = nil } }
}

/// Compares in time that depends only on the secret's length, not on how
/// much of it the other side guessed.
func constantTimeEquals(_ secret: [UInt8], _ proposed: [UInt8]) -> Bool {
    var difference = UInt8(truncatingIfNeeded: proposed.count ^ secret.count)
    for index in 0..<secret.count { difference |= secret[index] ^ (index < proposed.count ? proposed[index] : 0) }
    return difference == 0
}

let sessionCookieName = "andesite_session"
/// Cookie-authenticated requests that change anything must carry this.
let webClientValue = "web"

/// `/v1` accepts the bearer token, or a session cookie (with `X-Andesite-Client:
/// web` on any method but GET, HEAD and OPTIONS, which forces a CORS preflight a
/// foreign page cannot pass). Everything else needs the bearer token.
struct Authentication: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: [UInt8]
    let sessions: SessionStore

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let header = request.headers[.authorization] ?? ""
        let proposed = Array((header.hasPrefix("Bearer ") ? header.dropFirst(7) : "").utf8)
        // `POST /auth/session` takes the token in its body.
        var allowed = path == "/auth/session" || constantTimeEquals(token, proposed)
        if !allowed, path == "/v1" || path.hasPrefix("/v1/"), let id = request.cookies[sessionCookieName]?.value, sessions.isValid(id) {
            let reading = request.method == .get || request.method == .head || request.method == .options
            guard reading || request.headers[.init("X-Andesite-Client")!] == webClientValue else {
                return Self.reply(.forbidden, "client_header_required")
            }
            allowed = true
        }
        guard allowed else { return Self.reply(.unauthorized, "authentication_required") }
        do {
            return try await next(request, context)
        } catch let error as APIError {
            return Self.reply(error.status, error.code)
        }
    }

    static func reply(_ status: HTTPResponse.Status, _ code: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                 body: .init(byteBuffer: ByteBuffer(string: "{\"error\":\"\(code)\"}")))
    }
}

extension AndesiteHTTPServer {
    static func sessionCookie(_ value: String, maxAge: Int) -> String {
        "\(sessionCookieName)=\(value); Max-Age=\(maxAge); Path=/v1; HttpOnly; Secure; SameSite=Strict"
    }

    /// `POST /auth/session {"token"}` trades the API token for a cookie;
    /// `DELETE /auth/session` clears it. The cookie is scoped to `/v1`, so a
    /// browser does not send it to `/auth/…`: `DELETE /v1/session` is what
    /// ends the session on the server (the web client calls both).
    static func addSessionRoutes(_ router: Router<BasicRequestContext>, token: [UInt8], sessions: SessionStore) {
        router.post("/auth/session") { request, _ in
            let body = try await Data(buffer: request.body.collect(upTo: 4 * 1024))
            guard let proposed = (try? JSONDecoder().decode([String: String].self, from: body))?["token"] else {
                return response(failure(APIError(.badRequest, "invalid_json")))
            }
            guard constantTimeEquals(token, Array(proposed.utf8)) else { return Authentication.reply(.unauthorized, "authentication_required") }
            var reply = try json(["expiresIn": Int(sessions.lifetime)])
            reply.status = 201
            var out = response(reply)
            out.headers[.setCookie] = sessionCookie(sessions.create(), maxAge: Int(sessions.lifetime))
            return out
        }
        router.delete("/auth/session") { request, _ in
            if let id = request.cookies[sessionCookieName]?.value { sessions.revoke(id) }
            var out = Response(status: .noContent)
            out.headers[.setCookie] = sessionCookie("", maxAge: 0)
            out.headers[.cacheControl] = "no-store"
            return out
        }
        router.delete("/v1/session") { request, _ in
            if let id = request.cookies[sessionCookieName]?.value { sessions.revoke(id) }
            var out = Response(status: .noContent)
            out.headers[.setCookie] = sessionCookie("", maxAge: 0)
            out.headers[.cacheControl] = "no-store"
            return out
        }
    }
}
