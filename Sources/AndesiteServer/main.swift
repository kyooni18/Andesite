import Foundation
import AndesiteCore

// Local-only CLI. No HTTP listener is started, including with no arguments.
let args = Array(CommandLine.arguments.dropFirst())
do {
    guard args.count >= 5, ["init", "reconcile", "status", "search"].contains(args[0]),
          args[1] == "--vault", args[3] == "--state",
          (args[0] == "search" ? args.count == 6 : args.count == 5) else {
        FileHandle.standardError.write(Data("Usage: andesite-server <init|reconcile|status|search> --vault /absolute/vault --state /absolute/private-state [search-phrase]\nDirectories must already exist; state must be mode 0700. HTTP serving remains disabled.\n".utf8))
        exit(1)
    }
    let runtime = try VaultRuntime(configuration: VaultConfiguration(vaultDirectory: args[2], stateDirectory: args[4]))
    defer { runtime.shutdown() }
    switch args[0] {
    case "init", "reconcile":
        let report = try runtime.reconcile()
        print("discovered=\(report.discovered) revisionsCreated=\(report.revisionsCreated) unchanged=\(report.unchanged) invalidMarkdown=\(report.invalidMarkdown)")
    case "search":
        for hit in try runtime.search(args[5]) {
            print("\(hit.entryID.map { String(format: "%02x", $0) }.joined())\t\(hit.title)")
        }
    default:
        let status = try runtime.status()
        print("vault=\(status.vaultID.map { String(format: "%02x", $0) }.joined()) state=\(status.state) entries=\(status.entries) revisions=\(status.revisions) openIncidents=\(status.openIncidents)")
    }
} catch {
    FileHandle.standardError.write(Data("Andesite refused operation: \(error)\n".utf8))
    exit(1)
}
