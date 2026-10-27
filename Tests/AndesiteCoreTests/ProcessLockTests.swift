import Foundation
import Testing
@testable import AndesiteCore

@Test func processLockExcludesAndReleases() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let first = try ProcessLock(stateDirectory: root.path)
        try withExtendedLifetime(first) {
            #expect(throws: ProcessLockError.unavailable) { try ProcessLock(stateDirectory: root.path) }
        }
    }
    _ = try ProcessLock(stateDirectory: root.path)
}

@Test func lockRejectsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("server.lock"), withDestinationURL: root.appendingPathComponent("outside"))
    #expect(throws: (any Error).self) { try ProcessLock(stateDirectory: root.path) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
}
