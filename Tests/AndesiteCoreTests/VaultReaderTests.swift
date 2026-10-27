import Foundation
import Testing
@testable import AndesiteCore

@Test func safeVaultObservation() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let vault = base.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = vault.appendingPathComponent("nested/note.md")
    try Data("first\r\n".utf8).write(to: file)
    let reader = try VaultReader(rootPath: vault.path)
    let path = try VaultPath("nested/note.md")
    #expect(try reader.readStable(path, maximumBytes: 100, debounce: 0) == Data("first\r\n".utf8))
    try Data("external replacement".utf8).write(to: file, options: .atomic)
    #expect(try reader.readStable(path, maximumBytes: 100, debounce: 0) == Data("external replacement".utf8))
    #expect(throws: VaultReadError.unstable) {
        try reader.readStable(path, maximumBytes: 100, betweenObservations: {
            try Data("racing editor".utf8).write(to: file, options: .atomic)
        })
    }
    #expect(throws: VaultReadError.tooLarge) { try reader.readStable(path, maximumBytes: 2, debounce: 0) }
    for value in ["../escape", "/absolute", "a//b", "a/./b", "a\\b", "a\0b"] {
        #expect(throws: VaultReadError.invalidPath) { try VaultPath(value) }
    }
    try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("link"), withDestinationURL: base)
    #expect(throws: (any Error).self) { try reader.readStable(VaultPath("link/outside"), maximumBytes: 100, debounce: 0) }
    try FileManager.default.linkItem(at: file, to: vault.appendingPathComponent("hardlink"))
    #expect(throws: VaultReadError.unsafeFile) { try reader.readStable(path, maximumBytes: 100, debounce: 0) }
}
