import Foundation
import Testing
@testable import AndesiteCore

private func makeRegistryFixture() throws -> (RuntimeFixture, URL) {
    let fixture = try RuntimeFixture()
    return (fixture, fixture.root.appendingPathComponent(".andesite"))
}

@Test func vaultPathRegistryStoresOnlySelectedPathsWithoutScanningOrDatabase() throws {
    let (f, directory) = try makeRegistryFixture(); defer { f.clean() }
    try f.write("note.md", "# Should not be observed\nsecret-contents\n")
    let another = f.root.appendingPathComponent("another")
    try FileManager.default.createDirectory(at: another, withIntermediateDirectories: false)

    let registry = try VaultPathRegistry(directory: directory.path)
    #expect(try registry.list().isEmpty)
    #expect(try registry.add(f.vault.path))
    #expect(try !registry.add(f.vault.path))
    #expect(try registry.add(another.path))
    #expect(try registry.list() == [another.path, f.vault.path].sorted())

    let contents = try Data(contentsOf: directory.appendingPathComponent("vaults.json"))
    let paths = try JSONDecoder().decode([String].self, from: contents)
    #expect(paths == [another.path, f.vault.path].sorted())
    #expect(!String(decoding: contents, as: UTF8.self).contains("secret-contents"))
    #expect(!FileManager.default.fileExists(atPath: f.state.appendingPathComponent("catalog.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: f.vault.appendingPathComponent(".andesite").path))

    let onDisk = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("vaults.json").path)
    #expect((onDisk[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let dir = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((dir[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    let secondClient = try VaultPathRegistry(directory: directory.path)
    #expect(try secondClient.list() == registry.list())
    #expect(try registry.remove(f.vault.path))
    #expect(try !registry.remove(f.vault.path))
    #expect(try secondClient.list() == [another.path])
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"), encoding: .utf8) ==
            "# Should not be observed\nsecret-contents\n")
}

@Test func vaultPathRegistryKeepsDisconnectedSelectionAndRejectsUnsafePath() throws {
    let (f, directory) = try makeRegistryFixture(); defer { f.clean() }
    let registry = try VaultPathRegistry(directory: directory.path)
    #expect(try registry.add(f.vault.path))
    try FileManager.default.removeItem(at: f.vault)
    // A disconnected or removed Vault is still a registered location until
    // the user intentionally removes the path; no content recovery is inferred.
    #expect(try registry.list() == [f.vault.path])
    #expect(try registry.remove(f.vault.path))
    #expect(try registry.list().isEmpty)

    let bad = f.root.appendingPathComponent("not-a-vault")
    try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: f.state)
    #expect(throws: VaultPathRegistryError.invalidVaultPath) { try registry.add(bad.path) }
    #expect(throws: VaultPathRegistryError.invalidDirectory) { try registry.add("/tmp/../unsafe") }
    #expect(throws: VaultPathRegistryError.invalidDirectory) { try registry.remove("/tmp/./unsafe") }
    #expect(throws: VaultPathRegistryError.invalidDirectory) { try registry.remove("/tmp/new\nline") }
    #expect(try registry.list().isEmpty)
}

@Test func vaultPathRegistryFailsClosedOnUnsafeStorageAndNeverErasesContents() throws {
    let (f, directory) = try makeRegistryFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o755])
    #expect(throws: VaultPathRegistryError.unsafeRegistry) {
        try VaultPathRegistry(directory: directory.path)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let outside = f.root.appendingPathComponent("outside.json")
    try "[\"/not/ours\"]".write(to: outside, atomically: false, encoding: .utf8)
    let registryFile = directory.appendingPathComponent("vaults.json")
    try FileManager.default.createSymbolicLink(at: registryFile, withDestinationURL: outside)
    #expect(throws: VaultPathRegistryError.unsafeRegistry) {
        try VaultPathRegistry(directory: directory.path)
    }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "[\"/not/ours\"]")
    try FileManager.default.removeItem(at: registryFile)

    _ = try VaultPathRegistry(directory: directory.path)
    try Data("not json".utf8).write(to: registryFile)
    #expect(throws: VaultPathRegistryError.invalidContents) {
        try VaultPathRegistry(directory: directory.path)
    }
    #expect(try String(contentsOf: registryFile, encoding: .utf8) == "not json")
}
