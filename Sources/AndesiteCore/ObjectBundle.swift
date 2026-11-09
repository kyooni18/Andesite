import Foundation

/// Many whole objects in one body: per object, its 64-character hex hash,
/// its length as 8 bytes big-endian, then its bytes.
public enum ObjectBundle {
    static let frameOverhead = 64 + 8

    public static func append(_ hash: String, _ bytes: Data, to bundle: inout Data) {
        bundle.append(contentsOf: hash.utf8)
        withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { bundle.append(contentsOf: $0) }
        bundle.append(bytes)
    }

    public static func frames(_ bundle: Data) throws -> [(hash: String, bytes: Data)] {
        var frames: [(String, Data)] = [], at = bundle.startIndex
        while at < bundle.endIndex {
            guard bundle.endIndex - at >= frameOverhead else { throw SyncError.invalidBatch("bundle") }
            let hash = String(decoding: bundle[at..<at + 64], as: UTF8.self)
            let length = bundle[at + 64..<at + 72].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            at += frameOverhead
            guard ObjectStore.validHash(hash), length <= UInt64(bundle.endIndex - at) else { throw SyncError.invalidBatch("bundle") }
            frames.append((hash, Data(bundle[at..<at + Int(length)])))
            at += Int(length)
        }
        return frames
    }
}
