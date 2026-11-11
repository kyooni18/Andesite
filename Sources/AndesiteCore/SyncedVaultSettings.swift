import Foundation
import Crypto

/// The one hidden file shared by peers. Runtime paths, locks, workspace
/// state and other hidden files remain private to each vault copy.
enum SyncedVaultSettings {
    static let path = ".andesite/settings.json"
    // Both devices can create their settings before the first sync. A fixed
    // identity gives those versions one history instead of two competing files.
    static let entryID = Data(SHA256.hash(data: Data("andesite:vault-settings:v1".utf8)).prefix(16))

    static func permits(_ path: VaultPath, document: String) -> Bool {
        let name = path.components.joined(separator: "/")
        if name == Self.path { return document == entryID.hex }
        return document != entryID.hex && !path.components.contains { $0.hasPrefix(".") }
    }

    /// Three-way merge at preference boundaries. Independent edits survive;
    /// the greater revision wins if the same preference changed on both peers.
    static func merge(base: Data?, _ a: Data, _ b: Data) -> Data? {
        func object(_ data: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let left = object(a), let right = object(b) else { return nil }
        let original: [String: Any]
        if let base {
            guard let parsed = object(base) else { return nil }
            original = parsed
        } else { original = [:] }
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            NSDictionary(dictionary: a.map { ["value": $0] } ?? [:])
                .isEqual(to: b.map { ["value": $0] } ?? [:])
        }
        var merged = right
        for key in Set(original.keys).union(left.keys).union(right.keys) {
            if equal(right[key], original[key]) { merged[key] = left[key] }
        }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    }
}
