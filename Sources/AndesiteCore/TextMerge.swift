import Foundation

/// Line-based three-way merge (diff3). Lines are compared as exact bytes,
/// so Unicode-equivalent but different spellings are different lines.
/// Changes from `a` and `b` that touch separate base regions are combined;
/// a region both changed differently is a conflict (`nil`). The result does
/// not depend on argument order.
enum TextMerge {
    typealias Line = ArraySlice<UInt8>

    /// Larger edit distances are treated as conflicts instead of diffing.
    static let maximumEdits = 1000

    static func merge(base: Data, _ a: Data, _ b: Data) -> Data? {
        let (o, x, y) = (lines(base), lines(a), lines(b))
        guard let mx = matches(o, x), let my = matches(o, y) else { return nil }
        var output: [Line] = []
        var (i, j, k) = (0, 0, 0)
        while true {
            // The next base line kept unchanged by both sides.
            var stable = i
            while stable < o.count, mx[stable] == nil || my[stable] == nil { stable += 1 }
            let (je, ke) = stable < o.count ? (mx[stable]!, my[stable]!) : (x.count, y.count)
            let original = o[i..<stable], left = x[j..<je], right = y[k..<ke]
            if left.elementsEqual(original) {
                output += right
            } else if right.elementsEqual(original) || left.elementsEqual(right) {
                output += left
            } else {
                return nil
            }
            guard stable < o.count else { break }
            output.append(o[stable])
            (i, j, k) = (stable + 1, je + 1, ke + 1)
        }
        return Data(output.joined())
    }

    /// Lines including their terminators, so joining restores the bytes.
    static func lines(_ data: Data) -> [Line] {
        let bytes = [UInt8](data)
        var result: [Line] = [], start = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            result.append(bytes[start...index]); start = index + 1
        }
        if start < bytes.count { result.append(bytes[start...]) }
        return result
    }

    /// For each line of `old`, the index of the matching line in `new`
    /// (a longest common subsequence, Myers' algorithm). nil if the
    /// difference exceeds `maximumEdits`.
    static func matches(_ old: [Line], _ new: [Line]) -> [Int?]? {
        var result = [Int?](repeating: nil, count: old.count)
        // Common prefix and suffix need no search.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { result[prefix] = prefix; prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            result[old.count - 1 - suffix] = new.count - 1 - suffix; suffix += 1
        }
        let a = Array(old[prefix..<(old.count - suffix)]), b = Array(new[prefix..<(new.count - suffix)])
        let (n, m) = (a.count, b.count)
        guard n > 0, m > 0 else { return result }
        let limit = min(n + m, maximumEdits), offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...limit {
            trace.append(v)
            for diagonal in stride(from: -d, through: d, by: 2) {
                var x = diagonal == -d || (diagonal != d && v[offset + diagonal - 1] < v[offset + diagonal + 1])
                    ? v[offset + diagonal + 1] : v[offset + diagonal - 1] + 1
                var y = x - diagonal
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + diagonal] = x
                if x >= n, y >= m { found = true; break search }
            }
        }
        guard found else { return nil }
        // Walk the trace backwards, recording the diagonal (matching) moves.
        var (x, y) = (n, m)
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            if d == 0 {
                while x > 0, y > 0 { x -= 1; y -= 1; result[prefix + x] = prefix + y }
                break
            }
            let v = trace[d], diagonal = x - y
            let down = diagonal == -d || (diagonal != d && v[offset + diagonal - 1] < v[offset + diagonal + 1])
            let previous = down ? diagonal + 1 : diagonal - 1
            let px = v[offset + previous], start = down ? px : px + 1
            while x > start { x -= 1; y -= 1; result[prefix + x] = prefix + y }
            (x, y) = (px, px - previous)
        }
        return result
    }
}
