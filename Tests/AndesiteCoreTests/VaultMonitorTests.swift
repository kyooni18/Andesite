#if os(macOS)
import Foundation
import Testing
import Darwin
@testable import AndesiteCore

private func fastMonitorSettings(fallback: TimeInterval = 5) -> VaultMonitorSettings {
    VaultMonitorSettings(latency: 0.1, debounce: 0.2, maximumCoalescing: 0.75,
                         fallbackRescan: fallback, snapshotTick: 0.2,
                         polling: 0.04, retryDelay: 0.25)
}

@Test func watcherAutomaticallyObservesEditRenameCreationAndDeletion() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# One\noldword\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    let monitor = try VaultMonitor(runtime: runtime, vaultDirectory: f.vault.path,
                                   settings: fastMonitorSettings())
    let started = Date()
    var stage = 0
    var reports: [String] = []
    try monitor.run(shouldStop: { stage == 4 || Date().timeIntervalSince(started) > 15 },
        report: { text in
            reports.append(text)
            if text.hasPrefix("watch-ready") {
                try? f.write("note.md", "# Two\nnewword\n")
            }
            guard text.hasPrefix("watch-scan") else { return }
            switch stage {
            case 0 where (try? runtime.status().revisions) == 2:
                stage = 1
                try? FileManager.default.moveItem(at: f.vault.appendingPathComponent("note.md"),
                                                  to: f.vault.appendingPathComponent("renamed.md"))
            case 1 where (try? runtime.status().revisions) == 3:
                stage = 2
                try? f.write("temporary.md", "temporary words")
            case 2 where (try? runtime.status().revisions) == 4:
                stage = 3
                try? FileManager.default.removeItem(at: f.vault.appendingPathComponent("temporary.md"))
            case 3 where (try? runtime.status().revisions) == 5:
                stage = 4
            default: break
            }
        })
    #expect(stage == 4, "stage=\(stage), reports=\(reports)")
    #expect(try runtime.status().revisions == 5)
    let first = try #require(runtime.snapshots(path: "note.md").first)
    let moved = try #require(runtime.snapshots(path: "renamed.md").first)
    #expect(first.entryID == moved.entryID)
    #expect(try runtime.snapshots(path: "temporary.md").contains { $0.documentState == "deleted" })
    #expect(try runtime.search("newword").count == 1)
    try runtime.shutdown()
}

@Test func watcherPromotesDueSnapshotsAndPeriodicallyRescans() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Initial\noldword\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    try runtime.configureSnapshots(SnapshotPolicy(minimumInterval: 1, retentionSeconds: 60))
    let monitor = try VaultMonitor(runtime: runtime, vaultDirectory: f.vault.path,
                                   settings: fastMonitorSettings(fallback: 0.5))
    let started = Date()
    var observedPeriodic = false
    var observedDueSnapshot = false
    var edited = false
    var reports: [String] = []
    try monitor.run(shouldStop: {
        observedPeriodic && observedDueSnapshot || Date().timeIntervalSince(started) > 12
    }, report: { line in
        reports.append(line)
        if line.hasPrefix("watch-ready") {
            try? f.write("note.md", "# Updated\nnewword\n")
            edited = true
        }
        if line.contains("cause=periodic") { observedPeriodic = true }
        if line.hasPrefix("watch-snapshots-created") { observedDueSnapshot = true }
    })
    #expect(edited)
    #expect(observedPeriodic && observedDueSnapshot, "reports=\(reports)")
    #expect(try runtime.snapshots(path: "note.md").count == 2)
    #expect(try runtime.status().revisions == 2)
    try runtime.shutdown()
}

@Test func watcherRestartRecoversUnobservedChangesAfterSIGKILL() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Original\nfirsttoken\n")
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/andesite-server")
    let log = f.root.appendingPathComponent("watch.log")

    func spawn() throws -> Process {
        let p = Process()
        p.executableURL = executable
        p.arguments = ["watch", "--vault", f.vault.path, "--state", f.state.path]
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = try FileHandle(forWritingTo: log)
        p.standardError = p.standardOutput
        try p.run()
        return p
    }

    func ready(_ process: Process) throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let bytes = try? String(contentsOf: log, encoding: .utf8),
               bytes.contains("watch-ready") { return true }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return false
    }

    let initial = try spawn()
    guard try ready(initial) else {
        initial.terminate(); initial.waitUntilExit()
        Issue.record("watch initial startup failed")
        return
    }
    #expect(kill(initial.processIdentifier, SIGKILL) == 0)
    initial.waitUntilExit()
    // No FSEvents delivery while down. Startup must rescan all files.
    try f.write("note.md", "# During downtime\nsecondtoken\n")
    let restarted = try spawn()
    guard try ready(restarted) else {
        restarted.terminate(); restarted.waitUntilExit()
        Issue.record("watch restart failed")
        return
    }
    #expect(kill(restarted.processIdentifier, SIGTERM) == 0)
    restarted.waitUntilExit()
    #expect(restarted.terminationStatus == 0)
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.status().revisions == 2)
    #expect(try runtime.snapshots(path: "note.md").count == 2)
    #expect(try runtime.search("secondtoken").count == 1)
    try runtime.shutdown()
}
#endif
