import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AndesiteCore

private func fastMonitorSettings(fallback: TimeInterval = 5) -> VaultMonitorSettings {
    VaultMonitorSettings(latency: 0.1, debounce: 0.2, maximumCoalescing: 0.75,
                         fallbackRescan: fallback, snapshotTick: 0.2,
                         polling: 0.04, retryDelay: 0.25)
}

/// Polls `condition` until it holds or `seconds` elapse.
func eventually(_ seconds: TimeInterval = 10, _ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return try condition()
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func contains(_ text: String) -> Bool { lock.lock(); defer { lock.unlock() }; return lines.contains { $0.contains(text) } }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Test func watcherAutomaticallyObservesEditRenameCreationAndDeletion() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# One\noldword\n")
    let session = try VaultSession(vaultDirectory: f.vault.path, stateDirectory: f.state.path)
    let reports = Reports()
    try session.startWatching(settings: fastMonitorSettings(), report: reports.add)
    func revisions() throws -> Int { try session.run { try $0.status().revisions } }
    #expect(try eventually { try revisions() == 1 })
    try f.write("note.md", "# Two\nnewword\n")
    #expect(try eventually { try revisions() == 2 })
    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("note.md"), to: f.vault.appendingPathComponent("renamed.md"))
    #expect(try eventually { try revisions() == 3 })
    try f.write("temporary.md", "temporary words")
    #expect(try eventually { try revisions() == 4 })
    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("temporary.md"))
    #expect(try eventually { try revisions() == 5 }, "reports=\(reports.all)")
    try session.run { vault in
        let first = try #require(vault.snapshots(path: "note.md").first)
        let moved = try #require(vault.snapshots(path: "renamed.md").first)
        #expect(first.entryID == moved.entryID)
        #expect(try vault.snapshots(path: "temporary.md").contains { $0.documentState == "deleted" })
        #expect(try vault.searchIndexed("newword").count == 1)
    }
    try session.close()
}

@Test func watcherPromotesDueSnapshotsAndPeriodicallyRescans() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Initial\noldword\n")
    let session = try VaultSession(vaultDirectory: f.vault.path, stateDirectory: f.state.path)
    try session.run { try $0.configureSnapshots(SnapshotPolicy(minimumInterval: 1, retentionSeconds: 60)) }
    let reports = Reports()
    try session.startWatching(settings: fastMonitorSettings(fallback: 0.5), report: reports.add)
    #expect(eventually { reports.contains("watch-ready") })
    try f.write("note.md", "# Updated\nnewword\n")
    #expect(eventually { reports.contains("cause=periodic") }, "reports=\(reports.all)")
    #expect(try eventually { try session.run { try $0.snapshots(path: "note.md").count } == 2 }, "reports=\(reports.all)")
    #expect(try session.run { try $0.status().revisions } == 2)
    try session.close()
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
        p.arguments = ["watch", f.vault.path, "--state", f.state.path]
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
