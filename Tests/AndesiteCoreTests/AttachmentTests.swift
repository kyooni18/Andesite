import Foundation
import Testing
@testable import AndesiteCore

private func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

@Test func attachmentsAreTrackedRenamedAndLimitedWithoutFalseDeletes() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.vault.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try bytes(300_000).write(to: f.vault.appendingPathComponent("assets/photo.png"))
    try f.write("note.md", "# Note\n![[photo.png]]\n")
    let configuration = VaultConfiguration(vaultDirectory: f.vault.path, stateDirectory: f.state.path,
                                           maximumBytes: 1024, maximumFileBytes: 400_000, debounce: 0)
    var vault = try VaultRuntime(configuration: configuration)
    #expect(try vault.reconcile().revisionsCreated == 2)
    let photo = try vault.document("assets/photo.png")
    #expect(photo.kind == "attachment" && photo.byteLength == 300_000)
    // An unchanged scan reads nothing and creates nothing.
    #expect(try vault.reconcile().unchanged == 2)

    try FileManager.default.moveItem(at: f.vault.appendingPathComponent("assets/photo.png"),
                                     to: f.vault.appendingPathComponent("assets/renamed.png"))
    let renamed = try vault.reconcile()
    #expect(renamed.renamed == 1 && renamed.deleted == 0)
    #expect(try vault.document("assets/renamed.png").id == photo.id)

    // Growing past the limit leaves the file alone and does not delete it.
    try bytes(500_000).write(to: f.vault.appendingPathComponent("assets/renamed.png"))
    let oversize = try vault.reconcile()
    #expect(oversize.oversize == 1 && oversize.deleted == 0)
    #expect(try vault.document("assets/renamed.png").byteLength == 300_000)
    #expect(throws: VaultError.tooLarge) { try vault.create("big.bin", bytes(500_000)) }

    // Streaming create and read of an attachment larger than any note.
    let source = f.root.appendingPathComponent("upload.bin")
    try bytes(350_000, seed: 3).write(to: source)
    let streamed = try vault.create("files/upload.bin", contentsOf: source)
    let (_, fd) = try vault.openContent("files/upload.bin")
    let copy = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
    #expect(copy == bytes(350_000, seed: 3) && streamed.byteLength == 350_000)
    #expect(throws: VaultError.tooLarge) { try vault.read("files/upload.bin") }
    try vault.shutdown()
    vault = try VaultRuntime(configuration: configuration)
    #expect(try vault.reconcile().revisionsCreated == 0)
    try vault.shutdown()
}

@Test func chunkedTransferResumesAndRejectsCorruptContent() throws {
    let p = try Pair(); defer { p.close() }
    let content = bytes(1000)
    let source = try p.a.create("blob.bin", content)
    let size = Int64(content.count)
    // Interrupted after two chunks: the receiver keeps the progress.
    #expect(try p.b.receiveChunk(source.hash, size: size, offset: 0, content.prefix(300)) == 300)
    #expect(try p.b.receiveChunk(source.hash, size: size, offset: 300, content[300..<600]) == 600)
    #expect(try p.b.missingObjects([source.hash]) == [ObjectProgress(hash: source.hash, received: 600)])
    // A repeated or out-of-place chunk is ignored.
    #expect(try p.b.receiveChunk(source.hash, size: size, offset: 0, content.prefix(300)) == 600)
    try transfer(source.hash, size: size, from: p.a, to: p.b, chunk: 128)
    #expect(try p.b.missingObjects([source.hash]).isEmpty)

    // Bytes that do not hash to the claimed object are never stored under it.
    var forged = content
    forged[10] ^= 0xFF
    let other = ObjectStore.hash(bytes(1000, seed: 9))
    #expect(throws: SyncError.self) { try p.b.receiveChunk(other, size: size, offset: 0, forged) }
    #expect(try p.b.missingObjects([other]) == [ObjectProgress(hash: other, received: 0)])

    try sync(p.a, p.b)
    #expect(try p.b.openContent("blob.bin").document.hash == source.hash)
}

@Test func garbageCollectionKeepsEverythingReferenced() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let vault = try VaultRuntime(configuration: f.configuration)
    _ = try vault.reconcile()
    let first = try vault.create("note.md", Data("first version\n".utf8))
    let second = try vault.update("note.md", Data("second version\n".utf8), revision: first.revisionID)
    try vault.delete("note.md", revision: second.revisionID)
    let orphan = try vault.store(Data("never referenced\n".utf8), kind: "markdown")
    _ = try vault.receiveChunk(ObjectStore.hash(Data("partial".utf8)), size: 7, offset: 0, Data("par".utf8))

    // Young garbage is kept: a transfer may be about to use it.
    #expect(try vault.collectGarbage(minimumAge: 3600).removedObjects == 0)
    let report = try vault.collectGarbage(minimumAge: 0, now: Date().addingTimeInterval(10))
    #expect(report.removedObjects == 1 && report.removedPartials == 1)
    let objects = try vault.requireOpen().objects
    #expect(!objects.contains(orphan))
    #expect(objects.contains(first.hash) && objects.contains(second.hash)) // history of a deleted file
    #expect(try vault.restore("note.md", revision: first.revisionID).hash == first.hash)
    #expect(try vault.reconcile().revisionsCreated == 0)
    try vault.shutdown()
}
