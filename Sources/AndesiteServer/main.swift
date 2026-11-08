import Foundation
import AndesiteCore

// Local-first CLI. The opt-in Hummingbird API serves only 127.0.0.1 with bearer auth.
enum CLIError: Error { case usage; case invalidIdentifier; case invalidPolicy }
func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func identifier(_ text: String) throws -> Data {
    let value = text.replacingOccurrences(of: "-", with: "").lowercased()
    guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CLIError.invalidIdentifier }
    return Data(stride(from: 0, to: 32, by: 2).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
    })
}
func describe(_ snapshot: RecoverySnapshot) -> String {
    let formatter = ISO8601DateFormatter()
    return "snapshot=\(hex(snapshot.id)) document=\(hex(snapshot.entryID)) state=\(snapshot.documentState) path=\(snapshot.originalPath) created=\(formatter.string(from: snapshot.createdAt)) expires=\(formatter.string(from: snapshot.expiresAt)) eligible=\(snapshot.isExpired()) reason=\(snapshot.reason) hash=\(snapshot.contentHash) bytes=\(snapshot.byteLength) revision=\(hex(snapshot.revisionID)) observed=\(snapshot.observedAt)"
}
/// Manual, opt-in upload of immutable local history to a remote
/// authenticated Andesite server. This is a single-owner CLI: stop the
/// local watcher first, or use AndesiteBackend directly in the embedded app.
@MainActor
func runSyncPush(vault: String, state: String?, destination: URL,
                 peer: String, changesOnly: Bool) async throws {
    guard let secret = ProcessInfo.processInfo.environment["ANDESITE_API_TOKEN"] else {
        throw CLIError.usage
    }
    let transport = try AndesiteHTTPSyncClient(destination: destination, token: secret)
    let checkpoint = try transport.checkpointKey(peer: peer)
    let session = try VaultSession(vaultDirectory: vault, stateDirectory: state)
    do {
        _ = try session.reconcile()
        let backend = try session.backend
        var after = try backend.syncAcknowledgedSequence(peer: checkpoint)
        var changes = 0
        while true {
            let batch = try backend.syncChanges(after: after, limit: 8)
            if batch.changes.isEmpty { break }
            let receipt = try await transport.uploadChanges(batch)
            try backend.acknowledgeSync(peer: checkpoint, batch: batch, receipt: receipt)
            changes += batch.changes.count
            after = receipt.acknowledgedSequence
        }
        var snapshots = 0
        if !changesOnly {
            // Snapshot publication can lag behind a change event. A separate
            // durable acknowledgement set guarantees later snapshots are not
            // skipped after the event cursor has advanced.
            while true {
                let pending = try backend.pendingSyncSnapshots(peer: checkpoint, limit: 16)
                if pending.isEmpty { break }
                for id in pending {
                    let payload = try backend.syncSnapshot(id)
                    _ = try await transport.uploadSnapshot(payload)
                    try backend.acknowledgeSyncSnapshot(peer: checkpoint, snapshot: payload)
                    snapshots += 1
                }
            }
        }
        print("sync-push peer=\(peer) acknowledgedSequence=\(after) changes=\(changes) snapshots=\(snapshots) archivedOnly=true")
        try session.close()
    } catch {
        let failure = error
        try? session.close()
        throw failure
    }
}

let usage = """
Usage: andesite-server <command> --vault /absolute/vault --state /absolute/private-state [arguments]
  vault-add /absolute/vault         (create <vault>/.andesite/vault.json with path only)
  vault-info /absolute/vault        (read that Vault's saved path)
  vault-remove /absolute/vault      (forget that Vault's saved path without removing notes)
  vault-state /absolute/vault       (resolve default backend state path without creating it)
  vault-open /absolute/vault [--state /absolute/private-state]
                                   (connect, reconcile and close gracefully)
  vault-watch /absolute/vault [--state /absolute/private-state]
                                   (connect, reconcile, then continuously monitor until stopped)
  api-serve /absolute/vault [--port 8788] [--state /absolute/private-state]
                                   (authenticated loopback GET, conditional Markdown PUT and archive POST)
  sync-push /absolute/vault --to https://remote-host --peer stable-peer-name
                                   [--state /absolute/private-state] [--changes-only]
                                   (upload changes and snapshots to remote archive;
                                    stop this Vault's watcher first; requires ANDESITE_API_TOKEN)
  init | reconcile | status | search <phrase>
  watch    (macOS FSEvents plus same-user HTTP on state/andesite-read.sock; SIGINT/SIGTERM to stop)
  snapshots [document-id-or-historical-path]
  snapshot-inspect <snapshot-id>
  snapshot-compare <before-id> <after-id>
  snapshot-export <snapshot-id> /absolute/new-file-outside-vault-and-state
  read <path> | history <path> | mkdir <path> | mvdir <path> <new-path>
  write <path> [<revision>]  (create, or update when a revision is given; content on stdin)
  move <path> <new-path> <revision> | delete <path> <revision> | restore <path> <revision>
  snapshot-storage
  snapshot-config <minimum-interval-seconds> <retention-seconds>
Directories must already exist; state must be mode 0700.
The core/watch process has no TCP listener; optional api-serve binds 127.0.0.1.
Snapshot expiration is metadata only; no snapshots, revisions or objects are pruned.
"""
let args = Array(CommandLine.arguments.dropFirst())
do {
    if let command = args.first, ["vault-add", "vault-info", "vault-remove"].contains(command) {
        guard args.count == 2 else { throw CLIError.usage }
        let registry = try VaultPathRegistry(vaultDirectory: args[1])
        switch command {
        case "vault-add":
            print(try registry.register() ? "Saved Vault path: \(args[1])" : "Already registered: \(args[1])")
        case "vault-info":
            print(try registry.storedPath() ?? "Not registered: \(args[1])")
        default:
            print(try registry.unregister() ? "Removed saved path: \(args[1])" : "Not registered: \(args[1])")
        }
    } else if args.first == "sync-push" {
        guard args.count >= 6 else { throw CLIError.usage }
        let vault = args[1]
        var state: String?
        var destination: URL?
        var peer: String?
        var changesOnly = false
        var index = 2
        while index < args.count {
            if args[index] == "--changes-only" {
                changesOnly = true
                index += 1
                continue
            }
            guard index + 1 < args.count else { throw CLIError.usage }
            switch args[index] {
            case "--state": state = args[index + 1]
            case "--to": destination = URL(string: args[index + 1])
            case "--peer": peer = args[index + 1]
            default: throw CLIError.usage
            }
            index += 2
        }
        guard let destination, let peer else { throw CLIError.usage }
        try await runSyncPush(vault: vault, state: state,
                              destination: destination, peer: peer,
                              changesOnly: changesOnly)
    } else if args.first == "api-serve" {
        #if os(macOS)
        guard args.count >= 2 else { throw CLIError.usage }
        let vault = args[1]
        var port = 8788
        var state: String?
        var index = 2
        while index < args.count {
            guard index + 1 < args.count else { throw CLIError.usage }
            switch args[index] {
            case "--port":
                guard let candidate = Int(args[index + 1]) else { throw CLIError.usage }
                port = candidate
            case "--state":
                state = args[index + 1]
            default:
                throw CLIError.usage
            }
            index += 2
        }
        if #available(macOS 14.0, *) {
            try await AndesiteHTTPAPI.run(vault: vault, state: state, port: port)
        } else {
            throw CLIError.usage
        }
        #else
        throw CLIError.usage
        #endif
    } else if let command = args.first,
              ["vault-open", "vault-watch", "vault-state"].contains(command) {
        if command == "vault-state" {
            guard args.count == 2 else { throw CLIError.usage }
            print(try VaultSession.plannedStateDirectory(vaultDirectory: args[1]))
        } else {
            guard args.count == 2 || (args.count == 4 && args[2] == "--state") else {
                throw CLIError.usage
            }
            #if os(macOS)
            if command == "vault-watch" { VaultMonitor.installTerminationHandlers() }
            #endif
            let session = try VaultSession(vaultDirectory: args[1],
                                           stateDirectory: args.count == 4 ? args[3] : nil)
            do {
                if command == "vault-open" {
                    let report = try session.reconcile()
                    print("vault-open path=\(args[1]) state=\(session.stateDirectory) discovered=\(report.discovered) revisions=\(report.revisionsCreated) snapshots=\(report.snapshotsCreated)")
                } else {
                    #if os(macOS)
                    try session.watch(report: { line in
                        FileHandle.standardOutput.write(Data((line + "\n").utf8))
                    })
                    #else
                    throw CLIError.usage
                    #endif
                }
                try session.close()
            } catch {
                let failure = error
                do { try session.close() }
                catch {
                    FileHandle.standardError.write(Data("Vault closing also failed: \(error)\n".utf8))
                }
                throw failure
            }
        }
    } else {
    let counts: [String: ClosedRange<Int>] = ["init": 0...0, "reconcile": 0...0, "status": 0...0, "search": 1...1, "watch": 0...0,
        "snapshots": 0...1, "snapshot-inspect": 1...1, "snapshot-compare": 2...2, "snapshot-export": 2...2,
        "read": 1...1, "history": 1...1, "mkdir": 1...1, "mvdir": 2...2, "write": 1...2,
        "move": 3...3, "delete": 2...2, "restore": 2...2,
        "snapshot-storage": 0...0, "snapshot-config": 2...2]
    guard args.count >= 5, let count = counts[args[0]], count.contains(args.count - 5), args[1] == "--vault", args[3] == "--state" else { throw CLIError.usage }
    let runtime = try VaultRuntime(configuration: VaultConfiguration(vaultDirectory: args[2], stateDirectory: args[4]))
    do {
        switch args[0] {
        case "init", "reconcile":
            let report = try runtime.reconcile()
            print("discovered=\(report.discovered) revisionsCreated=\(report.revisionsCreated) unchanged=\(report.unchanged) invalidMarkdown=\(report.invalidMarkdown) deleted=\(report.deleted) renamed=\(report.renamed) snapshotsCreated=\(report.snapshotsCreated)")
        case "watch":
            #if os(macOS)
            // The API and watcher share one synchronous owner; neither
            // opens a second database connection or a TCP listening port.
            VaultMonitor.installTerminationHandlers()
            let monitor = try VaultMonitor(runtime: runtime, vaultDirectory: args[2])
            let api = try VaultLocalHTTP(runtime: runtime, stateDirectory: args[4])
            FileHandle.standardOutput.write(Data(
                "watch-api socket=\(api.socketPath) transport=unix-http access=same-user\n".utf8))
            try monitor.run(onIdle: { ready in
                try api.poll(indexReady: ready)
            }, report: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            })
            #else
            throw CLIError.usage
            #endif
        case "search":
            for hit in try runtime.search(args[5]) { print("\(hex(hit.entryID))\t\(hit.title)") }
        case "snapshots":
            let snapshots: [RecoverySnapshot]
            if args.count == 5 { snapshots = try runtime.snapshots() }
            else if let id = try? identifier(args[5]) { snapshots = try runtime.snapshots(entryID: id) }
            else { snapshots = try runtime.snapshots(path: args[5]) }
            for snapshot in snapshots { print(describe(snapshot)) }
        case "snapshot-inspect":
            let id = try identifier(args[5])
            var output = Data((describe(try runtime.inspectSnapshot(id)) + "\n--- contents ---\n").utf8)
            output.append(try runtime.snapshotContents(id))
            FileHandle.standardOutput.write(output)
        case "snapshot-compare":
            let comparison = try runtime.compareSnapshots(identifier(args[5]), identifier(args[6]))
            print("--- \(hex(comparison.before.id))\n+++ \(hex(comparison.after.id))")
            for change in comparison.changes { print(change) }
        case "snapshot-export":
            try runtime.exportSnapshot(identifier(args[5]), to: args[6])
            print("Exported verified bytes without overwriting: \(args[6])")
        case "read":
            FileHandle.standardOutput.write(try runtime.read(args[5]).content)
        case "write":
            // Bound stdin before anything is stored.
            let input = try FileHandle.standardInput.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            let document = args.count == 7 ?
                try runtime.update(args[5], input, revision: identifier(args[6])) :
                try runtime.create(args[5], input)
            print("document=\(hex(document.id)) revision=\(hex(document.revisionID)) path=\(document.path)")
        case "move":
            let document = try runtime.move(args[5], to: args[6], revision: identifier(args[7]))
            print("document=\(hex(document.id)) revision=\(hex(document.revisionID)) path=\(document.path)")
        case "delete":
            try runtime.delete(args[5], revision: identifier(args[6]))
            print("deleted=\(args[5])")
        case "restore":
            let document = try runtime.restore(args[5], revision: identifier(args[6]))
            print("document=\(hex(document.id)) revision=\(hex(document.revisionID)) path=\(document.path)")
        case "history":
            for r in try runtime.history(args[5]) {
                print("revision=\(hex(r.id)) document=\(hex(r.document)) parents=\(r.parents.map(hex).joined(separator: ",")) path=\(r.path) deleted=\(r.deleted) hash=\(r.hash ?? "-") origin=\(r.origin) created=\(r.created)")
            }
        case "mkdir":
            try runtime.createDirectory(args[5])
        case "mvdir":
            try runtime.moveDirectory(args[5], to: args[6])
        case "snapshot-config":
            guard let interval = Double(args[5]), let retention = Double(args[6]) else { throw CLIError.invalidPolicy }
            try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: interval, retentionSeconds: retention))
            print("Saved policy for new snapshots; existing expiration deadlines unchanged.")
        case "snapshot-storage":
            let storage = try runtime.snapshotStorage()
            print("minimumIntervalSeconds=\(storage.policy.minimumInterval) retentionSeconds=\(storage.policy.retentionSeconds) snapshots=\(storage.snapshots) expirationEligible=\(storage.expirationEligible) pendingDocuments=\(storage.pendingDocuments) logicalBytes=\(storage.logicalBytes) uniqueSnapshotBytes=\(storage.uniqueSnapshotBytes) registeredObjectBytes=\(storage.registeredObjectBytes) automaticPruning=false")
            print("immutableObjectLogicalBytes=\(storage.immutableObjectLogicalBytes) physicalObjectAllocatedBytes=\(storage.physicalObjectAllocatedBytes) temporaryObjectAllocatedBytes=\(storage.temporaryObjectAllocatedBytes) physicalNumbersAreAllocatedBlockEstimates=true snapshotLogicalBytesAreNotAdditionalPhysicalUsage=true")
            for object in storage.objects {
                print("\(object.contentHash) bytes=\(object.byteLength) snapshots=\(object.snapshots) revisions=\(object.revisions) incidents=\(object.incidents)")
            }
        default:
            let status = try runtime.status()
            print("vault=\(hex(status.vaultID)) state=\(status.state) entries=\(status.entries) revisions=\(status.revisions) openIncidents=\(status.openIncidents) unfinishedMutations=\(status.unfinishedMutations)")
        }
        try runtime.shutdown()
    } catch {
        let operationError = error
        do { try runtime.shutdown() }
        catch { FileHandle.standardError.write(Data("Snapshot flush also failed (captured revisions retained): \(error)\n".utf8)) }
        throw operationError
    }
    }
} catch {
    FileHandle.standardError.write(Data("Andesite refused operation: \(error)\n".utf8))
    if error is CLIError { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
    exit(1)
}
