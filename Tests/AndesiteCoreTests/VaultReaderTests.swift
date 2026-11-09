import Foundation
import Testing
@testable import AndesiteCore

@Test func safeVaultObservation() throws {
    let base = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path).appendingPathComponent(UUID().uuidString)
    let vault = base.appendingPathComponent("vault"), objects = base.appendingPathComponent("objects")
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = vault.appendingPathComponent("nested/note.md")
    try Data("first\r\n".utf8).write(to: file)
    try Data([0, 1, 2, 255]).write(to: vault.appendingPathComponent("nested/image.png"))
    let reader = try VaultReader(rootPath: vault.path), store = try ObjectStore(directory: objects.path)
    let path = try VaultPath("nested/note.md")
    #expect(try reader.files().map(\.kind) == ["attachment", "markdown"])

    func capture(maximum: Int = 100) throws -> Data {
        let (hash, _) = try reader.capture(path, expected: reader.fingerprint(path), into: store, maximumBytes: maximum)
        return try store.get(hash, maximumBytes: maximum)
    }
    #expect(try capture() == Data("first\r\n".utf8))
    try Data("external replacement".utf8).write(to: file, options: .atomic)
    #expect(try capture() == Data("external replacement".utf8))
    // A file that changed since it was scanned is not captured.
    let scanned = try reader.fingerprint(path)
    try Data("racing editor".utf8).write(to: file, options: .atomic)
    #expect(throws: VaultReadError.unstable) { try reader.capture(path, expected: scanned, into: store, maximumBytes: 100) }
    #expect(throws: VaultReadError.tooLarge) { try capture(maximum: 2) }
    for value in ["../escape", "/absolute", "a//b", "a/./b", "a\\b", "a\0b"] {
        #expect(throws: VaultReadError.invalidPath) { try VaultPath(value) }
    }
    try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("link"), withDestinationURL: base)
    #expect(throws: (any Error).self) { try reader.fingerprint(VaultPath("link/outside")) }
    try FileManager.default.linkItem(at: file, to: vault.appendingPathComponent("hardlink"))
    #expect(throws: VaultReadError.unsafeFile) { try capture() }
}
