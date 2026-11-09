import Foundation
import AndesiteCore
import AndesiteHTTP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let usage = """
Usage: andesite-server <command> <vault> [arguments] [--state <dir>]

Vault marker (writes only <vault>/.andesite/vault.json, never indexes):
  add | info | remove | state
Documents:
  open                                  scan once and close
  status | search <query>
  read <path> | history <path>
  write <path> [<revision>]             create, or update when a revision is given (stdin)
  move <path> <new-path> <revision>
  delete <path> <revision>
  restore <path> <revision>
  mkdir <path> | mvdir <path> <new-path>
Obsidian:
  links <path> [incoming]               outgoing links, or backlinks
  mentions <path>                       unlinked mentions
  tag <path> add|remove <tag> <revision>
  property <path> <name> <value>|- <revision>   (- removes; JSON values allowed)
Storage:
  gc [<minimum-age-days>]               remove unreferenced stored content (default 7 days)
Snapshots:
  snapshots [<path>] | snapshot <id> | snapshot-compare <id> <id>
  snapshot-export <id> <new-file> | snapshot-storage
  snapshot-config <min-interval-seconds> <retention-seconds>
Services (stop with SIGINT or SIGTERM):
  watch                                 monitor the Vault
  serve [--port 8788]                   watch and serve the HTTP API on 127.0.0.1
  sync <https://host[:port]> [--every <seconds>]
                                        two-way sync with a served Vault
serve and sync read the bearer token from ANDESITE_API_TOKEN (64 hex digits).
"""

struct UsageError: Error {}

func identifier(_ text: String) throws -> Data {
    guard let value = Data(hex: text.replacingOccurrences(of: "-", with: "").lowercased()), value.count == 16 else {
        throw UsageError()
    }
    return value
}

func describe(_ d: IndexedDocument) -> String {
    "document=\(d.id.hex) revision=\(d.revisionID.hex) path=\(d.path) bytes=\(d.byteLength)"
}

func describe(_ s: RecoverySnapshot) -> String {
    "snapshot=\(s.id.hex) document=\(s.entryID.hex) revision=\(s.revisionID.hex) state=\(s.documentState) path=\(s.originalPath) created=\(ISO8601DateFormatter().string(from: s.createdAt)) reason=\(s.reason) hash=\(s.contentHash) bytes=\(s.byteLength)"
}

func token() throws -> String {
    guard let token = ProcessInfo.processInfo.environment["ANDESITE_API_TOKEN"],
          AndesiteHTTPServer.isValidToken(token) else {
        FileHandle.standardError.write(Data("ANDESITE_API_TOKEN must be 64 hex digits\n".utf8))
        throw UsageError()
    }
    return token
}

/// Starts handling SIGINT and SIGTERM and returns a function that waits for
/// one. Install it before reporting readiness: once a signal is ignored, one
/// sent before its dispatch source is registered would be lost.
func terminationSignals() -> () -> Void {
    let stop = DispatchSemaphore(value: 0)
    let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stop.signal() }
        source.resume()
        return source
    }
    return { stop.wait(); withExtendedLifetime(sources) {} }
}

func report(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

/// Splits "--name value" options from positional arguments.
func parse(_ raw: [String]) throws -> (positional: [String], options: [String: String]) {
    var positional: [String] = [], options: [String: String] = [:], index = 0
    while index < raw.count {
        if raw[index].hasPrefix("--") {
            guard index + 1 < raw.count else { throw UsageError() }
            options[String(raw[index].dropFirst(2))] = raw[index + 1]
            index += 2
        } else {
            positional.append(raw[index]); index += 1
        }
    }
    return (positional, options)
}

func main() async throws {
    let (arguments, options) = try parse(Array(CommandLine.arguments.dropFirst()))
    guard arguments.count >= 2 else { throw UsageError() }
    let command = arguments[0], vaultPath = arguments[1], rest = Array(arguments.dropFirst(2))
    func expect(_ count: ClosedRange<Int>) throws { guard count.contains(rest.count) else { throw UsageError() } }

    switch command {
    case "add", "info", "remove":
        try expect(0...0)
        let marker = try VaultPathRegistry(vaultDirectory: vaultPath)
        switch command {
        case "add": print(try marker.register() ? "registered \(vaultPath)" : "already registered \(vaultPath)")
        case "info": print(try marker.storedPath() ?? "not registered")
        default: print(try marker.unregister() ? "removed marker" : "not registered")
        }
        return
    case "state":
        try expect(0...0)
        print(try VaultSession.plannedStateDirectory(vaultDirectory: vaultPath))
        return
    default: break
    }

    let session = try VaultSession(vaultDirectory: vaultPath, stateDirectory: options["state"])
    defer {
        do { try session.close() } catch { FileHandle.standardError.write(Data("closing failed: \(error)\n".utf8)) }
    }
    switch command {
    case "watch":
        try expect(0...0)
        let waitForTermination = terminationSignals()
        try session.startWatching(report: report)
        waitForTermination()
    case "serve":
        try expect(0...0)
        let secret = try token()
        guard let port = Int(options["port"] ?? "8788"), (0...65535).contains(port) else { throw UsageError() }
        try session.startWatching(report: report)
        try await AndesiteHTTPServer.run(session: session, token: secret, port: port) { bound in
            report("api-ready host=127.0.0.1 port=\(bound)")
        }
    case "sync":
        try expect(1...1)
        guard let url = URL(string: rest[0]) else { throw UsageError() }
        let client = try SyncClient(destination: url, token: token())
        let interval = options["every"].flatMap(Double.init)
        repeat {
            do {
                let r = try await client.sync(session)
                report("sync received=\(r.received) sent=\(r.sent) applied=\(r.applied) merged=\(r.merged) conflicts=\(r.conflicts) pending=\(r.pending)")
                for failure in r.failures { report("sync-pending \(failure)") }
            } catch where interval != nil {
                // Offline or interrupted: progress so far is kept; retry later.
                report("sync-failed error=\(error)")
            }
            if let interval { try await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000)) }
        } while interval != nil
    default:
        let input = command == "write" ? (try FileHandle.standardInput.readToEnd() ?? Data()) : Data()
        try session.run { vault in try runDocumentCommand(vault, command, rest, input: input) }
    }
}

func runDocumentCommand(_ vault: AndesiteBackend, _ command: String, _ rest: [String], input: Data) throws {
    func expect(_ count: ClosedRange<Int>) throws { guard count.contains(rest.count) else { throw UsageError() } }
    switch command {
    case "open":
        try expect(0...0)
        let r = try vault.reconcile()
        print("discovered=\(r.discovered) revisions=\(r.revisionsCreated) deleted=\(r.deleted) renamed=\(r.renamed) snapshots=\(r.snapshotsCreated)")
    case "status":
        try expect(0...0)
        let s = try vault.status()
        print("vault=\(s.vaultID.hex) state=\(s.state) entries=\(s.entries) revisions=\(s.revisions) openIncidents=\(s.openIncidents) unfinishedMutations=\(s.unfinishedMutations)")
    case "search":
        try expect(1...1)
        _ = try vault.reconcile()
        for hit in try vault.searchIndexed(rest[0]) { print("\(hit.path)\t\(hit.title)") }
    case "read":
        try expect(1...1)
        FileHandle.standardOutput.write(try vault.read(rest[0]).content)
    case "write":
        try expect(1...2)
        print(describe(rest.count == 2 ? try vault.update(rest[0], input, revision: identifier(rest[1]))
                                       : try vault.create(rest[0], input)))
    case "move":
        try expect(3...3)
        print(describe(try vault.move(rest[0], to: rest[1], revision: identifier(rest[2]))))
    case "delete":
        try expect(2...2)
        try vault.delete(rest[0], revision: identifier(rest[1]))
        print("deleted \(rest[0])")
    case "restore":
        try expect(2...2)
        print(describe(try vault.restore(rest[0], revision: identifier(rest[1]))))
    case "history":
        try expect(1...1)
        for r in try vault.history(rest[0]) {
            print("revision=\(r.id.hex) document=\(r.document.hex) parents=\(r.parents.map(\.hex).joined(separator: ",")) path=\(r.path) deleted=\(r.deleted) hash=\(r.hash ?? "-") origin=\(r.origin) created=\(r.created)")
        }
    case "mkdir":
        try expect(1...1)
        try vault.createDirectory(rest[0])
    case "mvdir":
        try expect(2...2)
        try vault.moveDirectory(rest[0], to: rest[1])
    case "snapshots":
        try expect(0...1)
        for s in try vault.snapshots(path: rest.first) { print(describe(s)) }
    case "snapshot":
        try expect(1...1)
        print(describe(try vault.inspectSnapshot(identifier(rest[0]))))
        FileHandle.standardOutput.write(try vault.snapshotContents(identifier(rest[0])))
    case "snapshot-compare":
        try expect(2...2)
        for change in try vault.compareSnapshots(identifier(rest[0]), identifier(rest[1])).changes { print(change) }
    case "snapshot-export":
        try expect(2...2)
        try vault.exportSnapshot(identifier(rest[0]), to: rest[1])
        print("exported \(rest[1])")
    case "snapshot-storage":
        try expect(0...0)
        let s = try vault.snapshotStorage()
        print("snapshots=\(s.snapshots) expirationEligible=\(s.expirationEligible) logicalBytes=\(s.logicalBytes) uniqueSnapshotBytes=\(s.uniqueSnapshotBytes) registeredObjectBytes=\(s.registeredObjectBytes) physicalObjectAllocatedBytes=\(s.physicalObjectAllocatedBytes)")
    case "links":
        try expect(1...2)
        let page = try vault.links(vault.document(rest[0]).id, direction: rest.count == 2 ? .incoming : .outgoing, limit: 500)
        for m in page.mentions {
            print("\(m.sourcePath)\t\(m.syntax)\t\(m.target)\(m.fragment.map { "#" + $0 } ?? "")\t\(m.status)\t\(m.documentPath ?? "-")\tfragment=\(m.fragmentStatus)")
        }
    case "mentions":
        try expect(1...1)
        for m in try vault.unlinkedMentions(vault.document(rest[0]).id, limit: 500) { print("\(m.sourcePath)\t\(m.term)") }
    case "tag":
        try expect(4...4)
        guard ["add", "remove"].contains(rest[1]) else { throw UsageError() }
        let revision = try identifier(rest[3])
        print(describe(rest[1] == "add" ? try vault.addTag(rest[0], rest[2], revision: revision)
                                        : try vault.removeTag(rest[0], rest[2], revision: revision)))
    case "property":
        try expect(4...4)
        var value: PropertyValue?
        if rest[2] != "-" {
            switch try? JSONSerialization.jsonObject(with: Data(rest[2].utf8), options: [.fragmentsAllowed]) {
            case let list as [String]: value = .list(list)
            case let flag as Bool where rest[2] == "true" || rest[2] == "false": value = .bool(flag)
            case let number as Double: value = .number(number)
            default: value = .text(rest[2])
            }
        }
        print(describe(try vault.setProperty(rest[0], rest[1], to: value, revision: identifier(rest[3]))))
    case "gc":
        try expect(0...1)
        let days = rest.first.flatMap(Double.init) ?? 7
        let g = try vault.collectGarbage(minimumAge: days * 86_400)
        print("removedObjects=\(g.removedObjects) removedBytes=\(g.removedBytes) removedPartials=\(g.removedPartials)")
    case "snapshot-config":
        try expect(2...2)
        guard let interval = Double(rest[0]), let retention = Double(rest[1]) else { throw UsageError() }
        try vault.configureSnapshots(SnapshotPolicy(minimumInterval: interval, retentionSeconds: retention))
    default:
        throw UsageError()
    }
}

do {
    try await main()
} catch is UsageError {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("andesite-server: \(error)\n".utf8))
    exit(1)
}
