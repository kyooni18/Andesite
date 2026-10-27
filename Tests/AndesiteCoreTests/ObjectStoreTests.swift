import Foundation
import Testing
@testable import AndesiteCore

@Test func immutableObjectsDetectCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ObjectStore(directory: root.path)
    let content = Data("hello".utf8)
    let hash = try store.put(content)
    #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    #expect(try store.put(content) == hash)
    #expect(try store.get(hash, maximumBytes: 5) == content)
    #expect(throws: ObjectStoreError.tooLarge) { try store.get(hash, maximumBytes: 4) }
    #expect(throws: ObjectStoreError.invalidHash) { try store.get("../outside", maximumBytes: 5) }
    try Data("wrong".utf8).write(to: root.appendingPathComponent(hash))
    #expect(throws: ObjectStoreError.corruptObject) { try store.get(hash, maximumBytes: 5) }
    #expect(throws: ObjectStoreError.corruptObject) { try store.put(content) }
    #expect(try Data(contentsOf: root.appendingPathComponent(hash)) == Data("wrong".utf8))
}
