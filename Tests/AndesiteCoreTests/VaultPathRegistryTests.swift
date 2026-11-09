import Foundation
import Testing
@testable import AndesiteCore

@Test func vaultPathMetadataLivesInsideEachVaultWithoutDatabaseOrScanning() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    try f.write("note.md", "# User note\nuseruniquephrase\n")
    let registry = try VaultPathRegistry(vaultDirectory: f.vault.path)
    let metadataDirectory = f.vault.appendingPathComponent(".andesite")
    let marker = metadataDirectory.appendingPathComponent("vault.json")

    #expect(try registry.storedPath() == nil)
    #expect(!FileManager.default.fileExists(atPath: metadataDirectory.path))
    #expect(try registry.register())
    #expect(try !registry.register())
    #expect(try registry.storedPath() == f.vault.path)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
    #expect(json?.count == 1 && (json?["path"] as? String) == f.vault.path)
    #expect(!String(decoding: try Data(contentsOf: marker), as: UTF8.self).contains("useruniquephrase"))
    let rootInfo = try FileManager.default.attributesOfItem(atPath: metadataDirectory.path)
    let markerInfo = try FileManager.default.attributesOfItem(atPath: marker.path)
    #expect((rootInfo[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((markerInfo[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(!FileManager.default.fileExists(atPath: f.state.appendingPathComponent("catalog.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".andesite").path))

    // Internal notes are intentionally ignored, even if somebody places a
    // Markdown file inside the private .andesite metadata directory.
    try "# Internal\ninternaluniquephrase\n".write(to: metadataDirectory.appendingPathComponent("internal.md"),
                                                       atomically: false, encoding: .utf8)
    let reader = try VaultReader(rootPath: f.vault.path)
    #expect(try reader.files().map { $0.path.components.joined(separator: "/") } == ["note.md"])
    let runtime = try VaultRuntime(configuration: f.configuration)
    #expect(try runtime.reconcile().discovered == 1)
    #expect(try runtime.search("useruniquephrase").count == 1)
    #expect(try runtime.search("internaluniquephrase").isEmpty)
    try runtime.shutdown()

    // Unregister only deletes the path marker, not .andesite's unrelated
    // contents, the existing notes, or the independent snapshot catalog.
    #expect(try registry.unregister())
    #expect(try !registry.unregister())
    #expect(try registry.storedPath() == nil)
    #expect(FileManager.default.fileExists(atPath: metadataDirectory.appendingPathComponent("internal.md").path))
    #expect(try String(contentsOf: f.vault.appendingPathComponent("note.md"), encoding: .utf8) ==
            "# User note\nuseruniquephrase\n")
    #expect(FileManager.default.fileExists(atPath: f.state.appendingPathComponent("catalog.sqlite").path))
}

@Test func vaultPathMetadataIsPerVaultAndCanRefreshMovedPath() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let secondVault = f.root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: secondVault, withIntermediateDirectories: false)
    let first = try VaultPathRegistry(vaultDirectory: f.vault.path)
    let second = try VaultPathRegistry(vaultDirectory: secondVault.path)
    #expect(try first.register())
    #expect(try second.register())
    #expect(try second.storedPath() == secondVault.path)
    #expect(try first.storedPath() == f.vault.path)

    let moved = f.root.appendingPathComponent("moved-vault")
    try FileManager.default.moveItem(at: f.vault, to: moved)
    let movedRegistry = try VaultPathRegistry(vaultDirectory: moved.path)
    #expect(try movedRegistry.storedPath() == f.vault.path)
    #expect(try movedRegistry.register())
    #expect(try movedRegistry.storedPath() == moved.path)
    #expect(try second.storedPath() == secondVault.path)
    #expect(try movedRegistry.unregister())
    #expect(try second.storedPath() == secondVault.path)
}

@Test func vaultPathMetadataRejectsSymlinksInsecureDirectoriesAndMalformedManifest() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let registry = try VaultPathRegistry(vaultDirectory: f.vault.path)
    let metadata = f.vault.appendingPathComponent(".andesite")
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)

    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
    #expect(throws: VaultPathRegistryError.unsafeRegistry) { try registry.register() }
    let unsafeReader = try VaultReader(rootPath: f.vault.path)
    #expect(try unsafeReader.files().isEmpty) // hidden entries are never followed
    try FileManager.default.removeItem(at: metadata)

    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o755])
    #expect(throws: VaultPathRegistryError.unsafeRegistry) { try registry.register() }
    #expect(try unsafeReader.files().isEmpty) // hidden entries are never followed
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metadata.path)

    let marker = metadata.appendingPathComponent("vault.json")
    try Data("not json".utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    #expect(throws: VaultPathRegistryError.invalidContents) { try registry.register() }
    #expect(try String(contentsOf: marker, encoding: .utf8) == "not json")
    try FileManager.default.removeItem(at: marker)

    let target = outside.appendingPathComponent("external.txt")
    try "unchanged".write(to: target, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
    #expect(throws: VaultPathRegistryError.unsafeRegistry) { try registry.register() }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    try FileManager.default.removeItem(at: marker)
    #expect(try registry.register())

    #expect(throws: VaultPathRegistryError.invalidDirectory) {
        try VaultPathRegistry(vaultDirectory: "/private/tmp/../unsafe")
    }
    #expect(throws: VaultPathRegistryError.invalidDirectory) {
        try VaultPathRegistry(vaultDirectory: "/private/tmp/path\nunsafe")
    }
}

@Test func hiddenDirectoriesAreNeverIndexed() throws {
    let f = try RuntimeFixture(); defer { f.clean() }
    let nested = f.vault.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: nested.appendingPathComponent(".andesite"),
                                             withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    try Data("# hidden".utf8).write(to: nested.appendingPathComponent(".andesite/secret.md"))
    let reader = try VaultReader(rootPath: f.vault.path)
    #expect(try reader.files().isEmpty)
}
