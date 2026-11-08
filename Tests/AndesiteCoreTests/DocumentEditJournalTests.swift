import Foundation
import Testing
@testable import AndesiteCore

@Test func conditionalEditPreservesOldBytesAndAtomicallyPublishesNewRevision() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let previous = "# Initial\n[[Other]]\nolduniquemarker\n"
    let requested = "# Edited\n[[Elsewhere]]\nnewuniquemarker\n"
    try f.write("note.md", previous)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let old = try #require(try runtime.documents().documents.first)
    let initialSnapshot = try #require(runtime.snapshots(path: "note.md").first)

    #expect(runtime.foregroundMutationGeneration == 0)
    let operation = try runtime.editDocument(old.id, expectedRevision: old.revisionID,
                                             contents: Data(requested.utf8))
    #expect(runtime.foregroundMutationGeneration == 1)
    #expect(operation.state == "completed")
    #expect(operation.entryID == old.id)
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                       encoding: .utf8) == requested)
    #expect(try runtime.snapshotContents(initialSnapshot.id) == Data(previous.utf8))
    #expect(try runtime.snapshotContents(operation.preimageID) == Data(previous.utf8))
    #expect(try runtime.status().state == "scanRequired")
    #expect(throws: VaultRuntimeError.inconsistentCatalog) {
        try runtime.inspectDocument(old.id)
    }

    _ = try runtime.reconcile()
    let current = try runtime.inspectDocument(old.id)
    #expect(current.revisionID == operation.revisionID)
    #expect(try runtime.documentContents(old.id) == Data(requested.utf8))
    #expect(try runtime.searchIndexed("newuniquemarker").count == 1)
    #expect(try runtime.searchIndexed("olduniquemarker").isEmpty)
    #expect(try runtime.mutationOperations().contains(where: {
        $0.id == operation.id && $0.state == "completed"
    }))
    let artifacts = try runtime.mutationArtifacts()
    #expect(artifacts.contains(where: { $0.operationID == operation.id }))

    // An HTTP/GUI retry with the same If-Match head must not create
    // a second write, even if it sends the same bytes.
    #expect(throws: MutationError.self) {
        try runtime.editDocument(old.id, expectedRevision: old.revisionID,
                                 contents: Data(requested.utf8))
    }
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                       encoding: .utf8) == requested)
    #expect(runtime.foregroundMutationGeneration == 1)
    try runtime.shutdown()
}

@Test func conditionalEditFailsClosedOnExternalConflictOrInvalidMarkdown() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Original\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let initial = try #require(try runtime.documents().documents.first)
    #expect(throws: (any Error).self) {
        try runtime.editDocument(initial.id, expectedRevision: Data(repeating: 0, count: 16),
                                 contents: Data("# Don't publish".utf8))
    }
    #expect(throws: (any Error).self) {
        try runtime.editDocument(initial.id, expectedRevision: initial.revisionID,
                                 contents: Data([0xff, 0xfe]))
    }
    try f.write("note.md", "# Editor won\n")
    #expect(throws: MutationError.self) {
        try runtime.editDocument(initial.id, expectedRevision: initial.revisionID,
                                 contents: Data("# Should never replace".utf8))
    }
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                       encoding: .utf8) == "# Editor won\n")
    _ = try runtime.reconcile()
    let new = try runtime.inspectDocument(initial.id)
    #expect(new.revisionID != initial.revisionID)
    #expect(try runtime.documentContents(initial.id) == Data("# Editor won\n".utf8))
    try runtime.shutdown()
}

#if os(macOS)
@Test func conditionalEditRecoversPublishedBytesAfterProcessKill() throws {
    for point in ["staged", "exchanged", "published", "catalogued"] {
        let f = try RuntimeFixture(); defer { f.clean() }
        try f.write("note.md", "# Before\noriginalversion\n")
        let runtime = try VaultRuntime(configuration: f.configuration)
        _ = try runtime.reconcile()
        let old = try #require(try runtime.documents().documents.first)
        try runtime.shutdown()
        let id = old.id.map { String(format: "%02x", $0) }.joined()
        let revision = old.revisionID.map { String(format: "%02x", $0) }.joined()
        let requested = Data("# After\npublishedversion\n".utf8)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/andesite-server")
        child.arguments = ["document-edit", "--vault", f.vault.path, "--state", f.state.path,
                           id, revision, "--stdin"]
        var environment = ProcessInfo.processInfo.environment
        environment["ANDESITE_TEST_FAULTS"] = "1"
        environment["ANDESITE_TEST_KILL_POINT"] = point
        child.environment = environment
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        try child.run()
        input.fileHandleForWriting.write(requested)
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(child.terminationReason == .uncaughtSignal &&
                child.terminationStatus == SIGKILL, "\(point): \(log)")

        let restart = try VaultRuntime(configuration: f.configuration)
        let operations = try restart.mutationOperations()
        let last = try #require(operations.last)
        let expected = point == "staged" ? "# Before\noriginalversion\n" : "# After\npublishedversion\n"
        #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                           encoding: .utf8) == expected)
        #expect(last.state == (point == "staged" ? "cancelled" : "completed"))
        _ = try restart.reconcile()
        let current = try restart.inspectDocument(old.id)
        if point != "staged" { #expect(current.revisionID == last.revisionID) }
        #expect(try restart.documentContents(old.id) == Data(expected.utf8))
        #expect(try restart.status().revisions == (point == "staged" ? 1 : 2))
        try restart.shutdown()
    }
}
#endif

#if os(macOS)
@Test func interruptedUserEditExposesCorrectIntendedBytesAndPreimage() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let source = "# Base\nbaseword\n"
    let requested = "# Desired\nuniquewanted\n"
    let concurrent = "# Other editor\notherword\n"
    try f.write("note.md", source)
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let original = try #require(try runtime.documents().documents.first)

    runtime.mutationFault = { point in
        if point == "before-exchange" {
            try f.write("note.md", concurrent)
        }
    }
    #expect(throws: MutationError.self) {
        try runtime.editDocument(original.id, expectedRevision: original.revisionID,
                                 contents: Data(requested.utf8))
    }
    runtime.mutationFault = nil
    let operation = try #require(try runtime.mutationOperations().last)
    #expect(operation.state == "staged")
    let inspection = try runtime.inspectMutation(operation.id)
    let intended = try #require(inspection.versions.first { $0.role == "intended" })
    let preimage = try #require(inspection.versions.first { $0.role == "preimage" })
    #expect(intended.hash == ObjectStore.hash(Data(requested.utf8)))
    #expect(intended.hash != preimage.hash)
    #expect(preimage.hash == ObjectStore.hash(Data(source.utf8)))
    let desiredOutput = f.root.appendingPathComponent("intended-export.md")
    let preimageOutput = f.root.appendingPathComponent("preimage-export.md")
    try runtime.exportMutationVersion(operation.id, role: "intended", to: desiredOutput.path)
    try runtime.exportMutationVersion(operation.id, role: "preimage", to: preimageOutput.path)
    #expect(try Data(contentsOf: desiredOutput) == Data(requested.utf8))
    #expect(try Data(contentsOf: preimageOutput) == Data(source.utf8))
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                       encoding: .utf8) == concurrent)

    // Reopening must preserve the competing editor bytes, and recovery
    // resolves the journal to quarantine instead of retrying the exchange.
    try runtime.shutdown()
    let reopened = try VaultRuntime(configuration: f.configuration)
    let held = try reopened.inspectMutation(operation.id)
    #expect(held.operation.state == "quarantined")
    #expect(held.versions.contains(where: {
        $0.role == "intended" && $0.hash == intended.hash
    }))
    #expect(held.choices.contains("preserve-current"))
    let resolution = try reopened.resolveMutation(operation.id, strategy: "preserve-current")
    #expect(resolution.state == "completed")
    _ = try reopened.reconcile()
    #expect(try reopened.searchIndexed("otherword").count == 1)
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"),
                       encoding: .utf8) == concurrent)
    #expect(try reopened.snapshotContents(operation.preimageID) == Data(source.utf8))
    try reopened.shutdown()
}
#endif

#if os(macOS)
@Test func cancelledEditStageIsOnlyRetiredAfterExactIntendedEvidenceVerification() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# Original\n")
    let runtime = try VaultRuntime(configuration: f.configuration)
    _ = try runtime.reconcile()
    let head = try #require(try runtime.documents().documents.first)
    let wanted = Data("# Proposed and cancelled\nretirement-proof\n".utf8)
    runtime.mutationFault = { point in
        if point == "staged" {
            throw MutationError.conflict("test pause after durable stage")
        }
    }
    #expect(throws: MutationError.self) {
        try runtime.editDocument(head.id, expectedRevision: head.revisionID,
                                 contents: wanted)
    }
    runtime.mutationFault = nil
    let operation = try #require(try runtime.mutationOperations().last)
    let inspect = try runtime.inspectMutation(operation.id)
    #expect(inspect.versions.contains(where: {
        $0.role == "intended" && $0.hash == ObjectStore.hash(wanted)
    }))
    try runtime.shutdown()

    let reopened = try VaultRuntime(configuration: f.configuration)
    #expect(try reopened.inspectMutation(operation.id).operation.state == "cancelled")
    #expect(try reopened.mutationArtifacts().contains(where: {
        $0.operationID == operation.id && $0.eligible
    }))
    let exported = f.root.appendingPathComponent("cancelled-intended.md")
    try reopened.exportMutationVersion(operation.id, role: "intended", to: exported.path)
    #expect(try Data(contentsOf: exported) == wanted)

    let retired = try reopened.cleanupMutationArtifacts(dryRun: false)
    #expect(retired.contains(where: {
        $0.operationID == operation.id && $0.status == "retired"
    }))
    #expect(try reopened.cleanupMutationArtifacts(dryRun: false)
        .contains(where: { $0.operationID == operation.id && $0.status == "retired" }))
    #expect(try Data(contentsOf: f.vault.appendingPathComponent("note.md"))
            == Data("# Original\n".utf8))
    _ = try reopened.reconcile()
    #expect(try reopened.inspectDocument(head.id).revisionID == head.revisionID)
    try reopened.shutdown()
}
#endif
