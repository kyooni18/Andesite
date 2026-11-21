import Foundation
import Testing
@testable import AndesiteCore
@testable import AndesiteHTTP

/// A JSON document, decoded so that booleans, integers and doubles stay apart.
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
}

/// The part of JSON Schema that `docs/schemas` uses: `type` (a name or a
/// list), `enum`, `pattern`, `minimum`, `required`, `properties`,
/// `additionalProperties: false`, `items`, `$ref` (a file or `#/$defs/x`).
struct SchemaValidator {
    let directory: URL

    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/schemas")

    func errors(_ data: Data, against file: String) throws -> [String] {
        let value = try JSONValue.parse(data)
        let root = try load(file)
        var found: [String] = []
        check(value, root, root: root, at: "$", &found)
        return found
    }

    private func load(_ file: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: directory.appendingPathComponent(file)))
    }

    private func check(_ value: JSONValue, _ schema: JSONValue, root: JSONValue, at path: String, _ errors: inout [String]) {
        guard case .object(let s) = schema else { errors.append("\(path): schema is not an object"); return }
        if case .string(let ref)? = s["$ref"] {
            if ref.hasPrefix("#/$defs/") {
                guard case .object(let r) = root, case .object(let defs)? = r["$defs"], let target = defs[String(ref.dropFirst(8))] else {
                    errors.append("\(path): unknown \(ref)"); return
                }
                check(value, target, root: root, at: path, &errors)
            } else if let target = try? load(ref) {
                check(value, target, root: target, at: path, &errors)
            } else { errors.append("\(path): cannot load \(ref)") }
            return
        }
        if let type = s["type"] {
            let names: [String]
            switch type {
            case .string(let n): names = [n]
            case .array(let list): names = list.compactMap { if case .string(let n) = $0 { n } else { nil } }
            default: names = []
            }
            guard names.contains(where: { matches(value, $0) }) else {
                errors.append("\(path): expected \(names.joined(separator: "|")), got \(value)"); return
            }
        }
        if case .array(let allowed)? = s["enum"], !allowed.contains(value) { errors.append("\(path): \(value) is not one of the allowed values") }
        if case .string(let pattern)? = s["pattern"], case .string(let text) = value,
           text.range(of: pattern, options: .regularExpression) == nil { errors.append("\(path): \(text) does not match \(pattern)") }
        if case .int(let minimum)? = s["minimum"] {
            if case .int(let n) = value, n < minimum { errors.append("\(path): \(n) < \(minimum)") }
        }
        if case .object(let object) = value {
            if case .array(let required)? = s["required"] {
                for case .string(let key) in required where object[key] == nil { errors.append("\(path): missing \(key)") }
            }
            let properties: [String: JSONValue]
            if case .object(let p)? = s["properties"] { properties = p } else { properties = [:] }
            for (key, member) in object {
                if let sub = properties[key] { check(member, sub, root: root, at: "\(path).\(key)", &errors) }
                else if case .bool(false)? = s["additionalProperties"] { errors.append("\(path): unexpected \(key)") }
            }
        }
        if case .array(let list) = value, let items = s["items"] {
            for (index, item) in list.enumerated() { check(item, items, root: root, at: "\(path)[\(index)]", &errors) }
        }
    }

    private func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
             ("integer", .int), ("number", .int), ("number", .double): return true
        default: return false
        }
    }
}

private func mustValidate(_ reply: (status: Int, body: Data, headers: [AnyHashable: Any]), _ status: Int, _ schema: String,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(reply.status == status, "HTTP \(reply.status): \(String(decoding: reply.body, as: UTF8.self))", sourceLocation: sourceLocation)
    let problems = try SchemaValidator(directory: SchemaValidator.docs).errors(reply.body, against: schema)
    #expect(problems.isEmpty, "\(schema): \(problems.joined(separator: "; ")) in \(String(decoding: reply.body, as: UTF8.self))",
            sourceLocation: sourceLocation)
}

private func jsonBody(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

@Test func theValidatorRejectsResponsesThatBreakTheSchema() throws {
    let validator = SchemaValidator(directory: SchemaValidator.docs)
    #expect(try validator.errors(Data(#"{"deleted":"a.md"}"#.utf8), against: "deleted.json").isEmpty)
    #expect(try validator.errors(Data(#"{"deleted":3}"#.utf8), against: "deleted.json").count == 1)
    #expect(try validator.errors(Data(#"{"deleted":"a","extra":1}"#.utf8), against: "deleted.json").count == 1)
    #expect(try validator.errors(Data(#"{}"#.utf8), against: "deleted.json").count == 1)
    // $ref into another file, and the enum on link status.
    let bad = #"{"links":[{"source":"a","target":"b","fragment":null,"display":null,"embed":false,"status":"odd","path":null,"fragmentStatus":"none"}],"total":1,"nextOffset":null}"#
    #expect(try validator.errors(Data(bad.utf8), against: "links.json").count == 1)
}

@Test func everyV1ResponseValidatesAgainstItsSchema() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("Other/Notes"), withIntermediateDirectories: true)
    try f.write("Notes/Alpha.md", """
        ---
        title: Alpha Note
        tags: [project, ideas]
        status: draft
        count: 3
        done: false
        aliases: [A]
        ---
        # Alpha

        See [[Beta]], [[Missing Page]] and [[Gamma#Heading]]. Also #inline-tag and an [external](https://example.com).

        ## Section Two
        Text about Beta here.

        """)
    try f.write("Notes/Beta.md", "# Beta\nLinks back to [[Alpha]]. Mentions Alpha in plain text.\n")
    try f.write("Notes/Plain.md", "# Plain\nThe word Beta appears without a link.\n")
    try f.write("Gamma.md", "# Gamma2\n")
    try f.write("Other/Notes/Gamma.md", "# Gamma\n## Heading\nx\n")
    try f.write("Broken.md", "---\n: : [unterminated\n---\n# Broken\n")
    let vault = try f.open()
    try vault.reconcile()
    let server = try await TestServer(vault)

    try mustValidate(try await server.request("GET", "/v1/status"), 200, "status.json")
    let documents = try await server.request("GET", "/v1/documents")
    try mustValidate(documents, 200, "documents.json")
    try mustValidate(try await server.request("GET", "/v1/documents?limit=2&offset=1"), 200, "documents.json")
    try mustValidate(try await server.request("GET", "/v1/documents?tag=project"), 200, "documents.json")
    try mustValidate(try await server.request("GET", "/v1/search?q=Beta"), 200, "search.json")
    try mustValidate(try await server.request("GET", "/v1/search?q=tag:project"), 200, "search.json")
    try mustValidate(try await server.request("GET", "/v1/tags"), 200, "tags.json")
    try mustValidate(try await server.request("GET", "/v1/properties"), 200, "properties.json")
    try mustValidate(try await server.request("GET", "/v1/metadata?path=Notes/Alpha.md"), 200, "metadata.json")
    try mustValidate(try await server.request("GET", "/v1/metadata?path=Broken.md"), 200, "metadata.json")
    try mustValidate(try await server.request("GET", "/v1/mentions?path=Notes/Alpha.md"), 200, "mentions.json")
    let outgoing = try await server.request("GET", "/v1/links?path=Notes/Alpha.md")
    try mustValidate(outgoing, 200, "links.json")
    let statuses = Set(try #require((try JSONSerialization.jsonObject(with: outgoing.body) as? [String: Any])?["links"] as? [[String: Any]])
        .compactMap { $0["status"] as? String })
    #expect(statuses.isSuperset(of: ["resolved", "missing", "ambiguous", "external"]))
    try mustValidate(try await server.request("GET", "/v1/links?path=Notes/Alpha.md&direction=incoming"), 200, "links.json")
    try mustValidate(try await server.request("GET", "/v1/history?path=Notes/Alpha.md"), 200, "history.json")
    try mustValidate(try await server.request("GET", "/v1/snapshots"), 200, "snapshots.json")
    let bookmarks = try await server.request("GET", "/v1/bookmarks")
    try mustValidate(bookmarks, 200, "bookmarks.json")

    // Writes.
    let created = try await server.request("PUT", "/v1/file?path=New.md", body: Data("# New\n".utf8), headers: ["If-None-Match": "*"])
    try mustValidate(created, 201, "document.json")
    let first = try #require((try JSONSerialization.jsonObject(with: created.body) as? [String: Any])?["revision"] as? String)
    let stale = try await server.request("PUT", "/v1/file?path=New.md", body: Data("# x\n".utf8), headers: ["If-Match": "\"\(String(repeating: "0", count: 32))\""])
    try mustValidate(stale, 412, "error.json")
    try mustValidate(try await server.request("GET", "/v1/file?path=Nope.md"), 404, "error.json")
    try mustValidate(try await server.request("GET", "/v1/search?q=x", token: "wrong"), 401, "error.json")
    let property = try await server.request("POST", "/v1/properties", body: jsonBody(["path": "New.md", "name": "status", "value": "draft", "revision": first]))
    try mustValidate(property, 200, "document.json")
    let second = try #require((try JSONSerialization.jsonObject(with: property.body) as? [String: Any])?["revision"] as? String)
    let tagged = try await server.request("POST", "/v1/tags", body: jsonBody(["path": "New.md", "revision": second, "add": "fresh"]))
    try mustValidate(tagged, 200, "document.json")
    let third = try #require((try JSONSerialization.jsonObject(with: tagged.body) as? [String: Any])?["revision"] as? String)
    let moved = try await server.request("POST", "/v1/move", body: jsonBody(["path": "New.md", "to": "Moved/New.md", "revision": third]))
    try mustValidate(moved, 200, "document.json")
    let fourth = try #require((try JSONSerialization.jsonObject(with: moved.body) as? [String: Any])?["revision"] as? String)
    try mustValidate(try await server.request("POST", "/v1/restore", body: jsonBody(["path": "Moved/New.md", "revision": first])), 200, "document.json")
    try mustValidate(try await server.request("POST", "/v1/directories", body: jsonBody(["path": "Empty"])), 200, "directory.json")
    _ = fourth
    let current = try await server.request("GET", "/v1/documents?limit=100")
    let live = try #require((try JSONSerialization.jsonObject(with: current.body) as? [String: Any])?["documents"] as? [[String: Any]])
        .first { $0["path"] as? String == "Moved/New.md" }
    let revision = try #require(live?["revision"] as? String)
    try mustValidate(try await server.request("DELETE", "/v1/file?path=Moved/New.md", headers: ["If-Match": "\"\(revision)\""]), 200, "deleted.json")

    // Bookmarks round trip.
    let version = try #require(bookmarks.headers["Etag"] as? String)
    let saved = try await server.request("PUT", "/v1/bookmarks", body: jsonBody(["items": [["type": "file", "ctime": 1, "path": "Notes/Alpha.md"]]]),
                                         headers: ["If-Match": version])
    try mustValidate(saved, 200, "bookmarks.json")

    await server.stop()
    try vault.close()
}

@Test func aServerOfSeveralVaultsListsThemAndAnswersSessionRequestsAgainstSchemas() async throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("main"), withIntermediateDirectories: false)
    try f.write("main/Hello.md", "# Hello\n")
    let library = VaultLibrary(root: f.vault.path, stateRoot: f.state.path)
    let server = try await LibraryServer(library)
    try mustValidate(try await server.request("GET", "/v1/vaults"), 200, "vaults.json")
    let login = try await server.request("POST", "/auth/session", body: jsonBody(["token": server.token]), bearer: false)
    try mustValidate(login, 201, "session.json")
    await server.stop()
}
