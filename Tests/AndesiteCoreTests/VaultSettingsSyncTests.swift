import Foundation
import Testing
@testable import AndesiteCore

@Test func vaultSettingsSyncMergesPreferencesWithoutExposingHiddenFiles() throws {
    let p = try Pair(); defer { p.close() }
    func write(_ side: RuntimeFixture, _ values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: side.vault.appendingPathComponent(".andesite"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: side.vault.appendingPathComponent(SyncedVaultSettings.path), options: .atomic)
    }
    func read(_ side: RuntimeFixture) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: side.vault.appendingPathComponent(SyncedVaultSettings.path))) as? [String: Any])
    }
    // Each app creates its preferences before it ever sees the other device.
    try write(p.fa, ["accentColor": "green"])
    try write(p.fb, ["editorFontSize": 18])
    try p.fa.write(".andesite/workspace.json", "{\"searchQuery\":\"local only\"}")
    try p.fa.write(".andesite/vault-path", "/private/device/state")
    try p.fa.write(".andesite/bookmarks.json", "{\"items\":[]}")
    try sync(p.a, p.b)
    try sync(p.a, p.b)
    #expect(try read(p.fa)["accentColor"] as? String == "green")
    #expect(try read(p.fa)["editorFontSize"] as? Int == 18)
    #expect(try p.converged())
    #expect(p.text(p.fb, ".andesite/workspace.json") == nil)
    #expect(p.text(p.fb, ".andesite/vault-path") == nil)
    #expect(p.text(p.fb, ".andesite/bookmarks.json") == nil)

    // Concurrent changes to separate preferences merge at key boundaries.
    try write(p.fa, ["accentColor": "pink", "editorFontSize": 18])
    try write(p.fb, ["accentColor": "green", "editorFontSize": 22])
    try sync(p.a, p.b)
    try sync(p.a, p.b)
    #expect(try read(p.fa)["accentColor"] as? String == "pink")
    #expect(try read(p.fa)["editorFontSize"] as? Int == 22)
    #expect(try p.converged())
    #expect(try p.a.files().isEmpty && p.b.files().isEmpty)
    #expect(try p.a.graphFiles().files.isEmpty)
    #expect(try p.a.documents().total == 0)
    #expect(try p.a.syncFeed(after: 0).records.allSatisfy { $0.path == SyncedVaultSettings.path })

    // A deletion/recreation still belongs to that same settings history.
    try FileManager.default.removeItem(at: p.fa.vault.appendingPathComponent(SyncedVaultSettings.path))
    try sync(p.a, p.b)
    #expect(p.text(p.fb, SyncedVaultSettings.path) == nil)
    try write(p.fb, ["accentColor": "blue"])
    try sync(p.a, p.b)
    #expect(try read(p.fa)["accentColor"] as? String == "blue")
    #expect(try p.converged())
}

@Test func settingsSyncStillRejectsOtherHiddenPathsAndLinkedFiles() throws {
    let p = try Pair(); defer { p.close() }
    try p.a.create("note.md", Data("note".utf8))
    let batch = try p.a.syncFeed(after: 0)
    for path in [".andesite/vault-path", ".andesite/workspace.json", ".andesite/settings.json/child", ".obsidian/app.json", SyncedVaultSettings.path] {
        var forged = batch
        forged.records[0].path = path
        forged.records[0].kind = "attachment"
        #expect(throws: SyncError.self) { try p.b.receive(forged) }
    }
    let outside = p.fa.root.appendingPathComponent("outside.json")
    try Data("{}".utf8).write(to: outside)
    let directory = p.fa.vault.appendingPathComponent(".andesite")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("settings.json"), withDestinationURL: outside)
    #expect(try VaultReader(rootPath: p.fa.vault.path).files().map { $0.path.components.joined(separator: "/") } == ["note.md"])
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: p.fa.root)
    #expect(try VaultReader(rootPath: p.fa.vault.path).files().count == 1)
}
