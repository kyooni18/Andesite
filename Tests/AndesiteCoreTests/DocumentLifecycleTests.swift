import Foundation
import Testing
@testable import AndesiteCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private extension RuntimeFixture {
    func text(_ name: String) throws -> String { try String(contentsOf: vault.appendingPathComponent(name), encoding: .utf8) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: vault.appendingPathComponent(name).path) }
    /// Journal artifacts are hidden ".andesite-<id>" files next to documents.
    func artifacts() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: vault.path)
        var found: [String] = []
        while let item = enumerator?.nextObject() as? String {
            if (item as NSString).lastPathComponent.hasPrefix(".andesite-") { found.append(item) }
        }
        return found
    }
}

@Test func documentLifecycleKeepsIdentityHistoryAndIndex() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()

    let created = try vault.create("노트/첫 노트.md", Data("# First\nalpha\n".utf8))
    #expect(try f.text("노트/첫 노트.md") == "# First\nalpha\n")
    #expect(try vault.read("노트/첫 노트.md").content == Data("# First\nalpha\n".utf8))
    #expect(throws: VaultError.alreadyExists("노트/첫 노트.md")) { try vault.create("노트/첫 노트.md", Data()) }
    #expect(try vault.search("alpha").map(\.path) == ["노트/첫 노트.md"])

    let updated = try vault.update("노트/첫 노트.md", Data("# First\nbeta\n".utf8), revision: created.revisionID)
    #expect(updated.id == created.id && updated.revisionID != created.revisionID)
    #expect(throws: VaultError.conflict(current: updated.revisionID)) {
        try vault.update("노트/첫 노트.md", Data("lost update".utf8), revision: created.revisionID)
    }
    // Identical content is not a new revision.
    #expect(try vault.update("노트/첫 노트.md", Data("# First\nbeta\n".utf8), revision: updated.revisionID).revisionID == updated.revisionID)

    let moved = try vault.move("노트/첫 노트.md", to: "Archive/2026/renamed.md", revision: updated.revisionID)
    #expect(moved.id == created.id && !f.exists("노트/첫 노트.md") && f.exists("노트"))
    #expect(try f.text("Archive/2026/renamed.md") == "# First\nbeta\n")

    try vault.delete("Archive/2026/renamed.md", revision: moved.revisionID)
    #expect(!f.exists("Archive/2026/renamed.md"))
    #expect(throws: VaultError.notFound("Archive/2026/renamed.md")) { try vault.read("Archive/2026/renamed.md") }

    let history = try vault.history("Archive/2026/renamed.md")
    #expect(history.map(\.id) == [created.revisionID, updated.revisionID, moved.revisionID, history[3].id])
    #expect(history[3].deleted && history[3].parents == [moved.revisionID] && history[1].parents == [created.revisionID])

    // Undelete the first version at its original location.
    let restored = try vault.restore("노트/첫 노트.md", revision: created.revisionID)
    #expect(restored.id == created.id && restored.hash == created.hash)
    #expect(try f.text("노트/첫 노트.md") == "# First\nalpha\n")
    #expect(try vault.history("노트/첫 노트.md").last?.origin == "restore")
    #expect(try vault.search("alpha").count == 1 && vault.search("beta").isEmpty)

    // Restoring a live document to an older revision is an ordinary child.
    let edited = try vault.update("노트/첫 노트.md", Data("gamma".utf8), revision: restored.revisionID)
    let back = try vault.restore("노트/첫 노트.md", revision: updated.revisionID)
    #expect(try vault.history("노트/첫 노트.md").last?.parents == [edited.revisionID])
    #expect(back.hash == updated.hash && f.artifacts().isEmpty)

    // The catalog matches the disk exactly: a rescan finds nothing new.
    let rescan = try vault.reconcile()
    #expect(rescan.revisionsCreated == 0 && rescan.deleted == 0 && rescan.renamed == 0)
    #expect(try vault.status().unfinishedMutations == 0)
    try vault.shutdown()
}

@Test func externalChangesAreCapturedNeverOverwritten() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let doc = try vault.create("note.md", Data("original".utf8))
    try f.write("note.md", "edited in another app")
    for attempt in [
        { _ = try vault.update("note.md", Data("mine".utf8), revision: doc.revisionID) },
        { _ = try vault.move("note.md", to: "elsewhere.md", revision: doc.revisionID) },
        { try vault.delete("note.md", revision: doc.revisionID) }
    ] {
        #expect(throws: VaultError.self, performing: attempt)
        #expect(try f.text("note.md") == "edited in another app")
    }
    // The external edit became the new head, so a retry against it works.
    let current = try vault.document("note.md")
    #expect(current.revisionID != doc.revisionID && current.hash == ObjectStore.hash(Data("edited in another app".utf8)))
    _ = try vault.update("note.md", Data("mine".utf8), revision: current.revisionID)
    #expect(try f.text("note.md") == "mine")

    // A writer racing between verification and the atomic exchange (or the
    // rename for deletion) is detected and its version is put back.
    for point in ["update", "delete"] {
        let head = try vault.document("note.md")
        vault.mutationFault = { if $0 == "verified" { try Data("racing write \(point)".utf8).write(to: f.vault.appendingPathComponent("note.md")) } }
        #expect(throws: VaultError.self) {
            if point == "update" { _ = try vault.update("note.md", Data("loser".utf8), revision: head.revisionID) }
            else { try vault.delete("note.md", revision: head.revisionID) }
        }
        vault.mutationFault = nil
        #expect(try f.text("note.md") == "racing write \(point)" && f.artifacts().isEmpty)
    }
    try vault.shutdown()
}

@Test func namespaceCollisionsInvalidPathsAndSymlinksAreRefused() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let note = try vault.create("Note.md", Data("one".utf8))
    let cafe = try vault.create("Cafe\u{301}.md", Data("nfd".utf8))
    #expect(throws: VaultError.alreadyExists("note.md")) { try vault.create("note.md", Data("two".utf8)) }
    #expect(throws: VaultError.alreadyExists("Caf\u{e9}.md")) { try vault.create("Caf\u{e9}.md", Data("nfc".utf8)) }
    #expect(throws: VaultError.alreadyExists("Note.md")) { try vault.move("Cafe\u{301}.md", to: "Note.md", revision: cafe.revisionID) }
    #expect(try f.text("Note.md") == "one")
    for bad in ["../escape.md", "/absolute.md", ".obsidian/app.md", "a/.hidden.md", "", "a//b.md", "nul\u{0}.md"] {
        #expect(throws: VaultError.invalidPath(bad)) { try vault.create(bad, Data("x".utf8)) }
    }
    // A case-only rename of the same file is allowed.
    let renamed = try vault.move("Note.md", to: "NOTE.md", revision: note.revisionID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.vault.path).contains("NOTE.md"))
    #expect(renamed.path == "NOTE.md" && renamed.id == note.id)
    // Existing folders keep their on-disk spelling on case-insensitive volumes.
    _ = try vault.create("Projects/a.md", Data("a".utf8))
    let b = try vault.create("projects/b.md", Data("b".utf8))
    #expect(b.path == "Projects/b.md" || FileManager.default.fileExists(atPath: f.vault.appendingPathComponent("projects").path))

    // Symlinked folders and files are never followed or replaced.
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("target.md"))
    try FileManager.default.createSymbolicLink(at: f.vault.appendingPathComponent("linked"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: f.vault.appendingPathComponent("evil.md"),
                                               withDestinationURL: outside.appendingPathComponent("target.md"))
    #expect(throws: VaultError.self) { try vault.create("linked/new.md", Data("x".utf8)) }
    #expect(throws: VaultError.alreadyExists("evil.md")) { try vault.create("evil.md", Data("x".utf8)) }
    #expect(throws: VaultError.self) { try vault.move("NOTE.md", to: "linked/stolen.md", revision: renamed.revisionID) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["target.md"])
    #expect(try String(contentsOf: outside.appendingPathComponent("target.md"), encoding: .utf8) == "secret")
    // Replacing a catalogued file with a symlink is an external change.
    try FileManager.default.removeItem(at: f.vault.appendingPathComponent("NOTE.md"))
    try FileManager.default.createSymbolicLink(at: f.vault.appendingPathComponent("NOTE.md"),
                                               withDestinationURL: outside.appendingPathComponent("target.md"))
    #expect(throws: VaultError.self) { try vault.update("NOTE.md", Data("overwrite".utf8), revision: renamed.revisionID) }
    #expect(try String(contentsOf: outside.appendingPathComponent("target.md"), encoding: .utf8) == "secret")
    #expect(f.artifacts().isEmpty)
    try vault.shutdown()
}

@Test func directoriesAreCreatedAndMovedAtomically() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    try vault.createDirectory("Empty/Nested")
    #expect(f.exists("Empty/Nested"))
    let a = try vault.create("Projects/a.md", Data("a".utf8))
    let b = try vault.create("Projects/sub/b.md", Data("b".utf8))
    _ = try vault.create("Archive/Projects/c.md", Data("c".utf8))
    #expect(throws: VaultError.alreadyExists("Archive/Projects")) { try vault.moveDirectory("Projects", to: "Archive/Projects") }
    #expect(throws: VaultError.invalidPath("Projects/sub/inside")) { try vault.moveDirectory("Projects", to: "Projects/sub/inside") }
    try vault.moveDirectory("Projects", to: "Done/2026")
    #expect(!f.exists("Projects") && f.exists("Done/2026/sub/b.md"))
    #expect(try vault.document("Done/2026/a.md").id == a.id)
    #expect(try vault.document("Done/2026/sub/b.md").id == b.id)
    #expect(try vault.history("Done/2026/sub/b.md").last?.parents == [b.revisionID])
    let rescan = try vault.reconcile()
    #expect(rescan.revisionsCreated == 0 && rescan.deleted == 0)
    try vault.shutdown()
}

#if os(macOS) || os(Linux)
/// Kills a real CLI process at each journal boundary, restarts and checks
/// that files and catalog agree on exactly the old or exactly the new state.
@Test func sigkillAtEveryMutationPhaseRecoversConsistently() throws {
    let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/andesite-server")
    let points = ["intent", "staged", "verified", "published", "removed", "before-commit", "committed", "done"]
    let applied: Set<String> = ["published", "removed", "before-commit", "committed", "done"]
    for operation in ["create", "update", "move", "delete", "restore-elsewhere", "mvdir"] {
        for point in points {
            let f = try RuntimeFixture(); defer { f.clean() }
            var first: IndexedDocument?
            do {
                let vault = try VaultRuntime(configuration: f.configuration)
                _ = try vault.reconcile()
                first = try vault.create("dir/note.md", Data("# Old\nold\n".utf8))
                _ = try vault.update("dir/note.md", Data("# Old\nolder\n".utf8), revision: first!.revisionID)
                try vault.shutdown()
            }
            let head = try { () throws -> IndexedDocument in
                let v = try VaultRuntime(configuration: f.configuration); defer { try? v.shutdown() }
                return try v.document("dir/note.md")
            }()
            var arguments: [String]
            var input = Data()
            switch operation {
            case "create": arguments = ["write", "new/created.md"]; input = Data("# New\nnew\n".utf8)
            case "update": arguments = ["write", "dir/note.md", head.revisionID.hex]; input = Data("# New\nnew\n".utf8)
            case "move": arguments = ["move", "dir/note.md", "moved/note.md", head.revisionID.hex]
            case "delete": arguments = ["delete", "dir/note.md", head.revisionID.hex]
            case "restore-elsewhere": arguments = ["restore", "restored.md", first!.revisionID.hex]
            default: arguments = ["mvdir", "dir", "renamed"]
            }
            let child = Process()
            child.executableURL = binary
            child.arguments = [arguments[0], f.vault.path] + arguments.dropFirst() + ["--state", f.state.path]
            var environment = ProcessInfo.processInfo.environment
            environment["ANDESITE_TEST_FAULTS"] = "1"
            environment["ANDESITE_TEST_KILL_POINT"] = point
            child.environment = environment
            let stdin = Pipe(), output = Pipe()
            child.standardInput = stdin; child.standardOutput = output; child.standardError = output
            try child.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            child.waitUntilExit()
            let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let killed = child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL
            #expect(killed || child.terminationStatus == 0, "\(operation)@\(point): \(log)")

            let vault = try VaultRuntime(configuration: f.configuration)
            #expect(try vault.status().unfinishedMutations == 0)
            #expect(f.artifacts().isEmpty, "\(operation)@\(point) left \(f.artifacts())")
            // A relocation publishes the new file before setting the old one aside.
            let new = !killed || applied.contains(point) || (operation == "restore-elsewhere" && point == "verified")
            switch operation {
            case "create":
                #expect(f.exists("new/created.md") == new, "\(operation)@\(point)")
                #expect(((try? vault.document("new/created.md")) != nil) == new)
            case "update":
                #expect(try f.text("dir/note.md") == (new ? "# New\nnew\n" : "# Old\nolder\n"), "\(operation)@\(point)")
                #expect((try vault.document("dir/note.md").revisionID != head.revisionID) == new)
            case "move":
                #expect(f.exists("moved/note.md") == new && f.exists("dir/note.md") == !new, "\(operation)@\(point)")
                #expect(try vault.document(new ? "moved/note.md" : "dir/note.md").id == head.id)
            case "delete":
                #expect(f.exists("dir/note.md") == !new, "\(operation)@\(point)")
                #expect(((try? vault.document("dir/note.md")) == nil) == new)
            case "restore-elsewhere":
                #expect(f.exists("restored.md") == new && f.exists("dir/note.md") == !new, "\(operation)@\(point)")
                if new { #expect(try f.text("restored.md") == "# Old\nold\n") }
            default:
                #expect(f.exists("renamed/note.md") == new && f.exists("dir/note.md") == !new, "\(operation)@\(point)")
                #expect(try vault.document(new ? "renamed/note.md" : "dir/note.md").id == head.id)
            }
            // Files and catalog agree: a rescan must find nothing to record.
            let rescan = try vault.reconcile()
            #expect(rescan.revisionsCreated == 0 && rescan.deleted == 0, "\(operation)@\(point): \(rescan)")
            try vault.shutdown()
        }
    }
}
#endif

/// Fills a real filesystem. Run with ANDESITE_TEST_SMALL_FS pointing at a
/// small, disposable one (scripts/test-linux.sh mounts a 16 MiB tmpfs).
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANDESITE_TEST_SMALL_FS"] != nil))
func fullDiskFailsCleanlyAndRecovers() throws {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANDESITE_TEST_SMALL_FS"]!).appendingPathComponent(UUID().uuidString)
    let vaultURL = base.appendingPathComponent("vault"), state = base.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let filler = base.appendingPathComponent("filler")
    try Data(repeating: 0, count: 6 << 20).write(to: filler) // freed later; more than the WAL can grow
    let configuration = VaultConfiguration(vaultDirectory: vaultURL.path, stateDirectory: state.path, debounce: 0)
    var vault = try VaultRuntime(configuration: configuration)
    _ = try vault.reconcile()

    var acknowledged: [String: Data] = [:]
    var failure: Error?, failed: (String, Data)?
    for i in 0..<10_000 {
        let content = Data((String(repeating: "note \(i) ", count: 2000) + "\n").utf8)
        do { try vault.create("n\(i).md", content); acknowledged["n\(i).md"] = content } catch {
            failure = error; failed = ("n\(i).md", content); break
        }
    }
    #expect(failure.map(VaultError.isStorageFull) == true, "\(String(describing: failure))")
    #expect(acknowledged.count > 3)
    // Reads still work while the disk is full.
    let sample = try #require(acknowledged.first)
    #expect(try vault.read(sample.key).content == sample.value)

    try FileManager.default.removeItem(at: filler)
    // Every acknowledged write is intact, nothing unacknowledged is visible,
    // and disk and catalog agree.
    let check = try vault.reconcile()
    #expect(check.revisionsCreated == 0 && check.deleted == 0 && check.invalidMarkdown == 0, "\(check)")
    // A write whose catalog commit failed after its file was published is
    // completed by recovery, as after a crash: then it is exactly that write.
    if let (path, content) = failed, (try? vault.document(path)) != nil {
        #expect(try vault.read(path).content == content)
        acknowledged[path] = content
    }
    let status = try vault.status()
    #expect(status.entries == acknowledged.count && status.unfinishedMutations == 0, "\(status) acknowledged=\(acknowledged.count)")
    try vault.create("after.md", Data("space again\n".utf8))
    try vault.shutdown()
    vault = try VaultRuntime(configuration: configuration) // integrity check on open
    for (path, content) in acknowledged { #expect(try vault.read(path).content == content) }
    let reopened = try vault.reconcile()
    #expect(reopened.revisionsCreated == 0 && reopened.deleted == 0)
    try vault.shutdown()
}
