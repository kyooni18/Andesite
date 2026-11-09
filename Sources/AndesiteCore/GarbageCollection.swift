import Foundation

public struct GarbageReport: Sendable, Equatable {
    public var removedObjects = 0
    public var removedBytes: Int64 = 0
    public var removedPartials = 0
}

extension VaultRuntime {
    /// Removes stored content nothing refers to: not a revision (history,
    /// conflicts, tombstoned documents' earlier versions), a recovery
    /// snapshot, an incident or an unfinished mutation. Content younger than
    /// `minimumAge` is kept, because a sync transfer or an upload may be
    /// about to reference it; so are interrupted transfers.
    @discardableResult
    public func collectGarbage(minimumAge: TimeInterval = 7 * 86_400, now: Date = Date()) throws -> GarbageReport {
        let r = try requireOpen()
        try journal().recover()
        var referenced = Set<String>()
        for query in ["SELECT DISTINCT lower(hex(content_hash)) FROM revisions WHERE content_hash IS NOT NULL",
                      "SELECT DISTINCT lower(hex(content_hash)) FROM incidents",
                      "SELECT DISTINCT lower(hex(content_hash)) FROM recovery_snapshots"] {
            for row in try r.db.queryValues(query) { if case .text(let hash) = row[0] { referenced.insert(hash.lowercased()) } }
        }
        for row in try r.db.queryValues("SELECT plan FROM mutations") {
            guard case .text(let json) = row[0] else { continue }
            let plan = try JSONDecoder().decode(MutationPlan.self, from: Data(json.utf8))
            referenced.formUnion([plan.fromHash, plan.toHash].compactMap { $0 })
        }
        var report = GarbageReport()
        let cutoff = now.timeIntervalSince1970 - minimumAge
        for item in try r.objects.listing() where item.modified < cutoff {
            if ObjectStore.validHash(item.name) {
                guard !referenced.contains(item.name) else { continue }
                // Unregister first: a crash in between leaves only an orphan
                // file, never a registered object that is missing.
                try r.db.executeValues("DELETE FROM objects WHERE hash=?", bindings: [.blob(Data(hex: item.name)!)])
                try r.objects.remove(item.name)
                report.removedObjects += 1
                report.removedBytes += item.size
            } else if item.name.hasPrefix(".object-") {
                try r.objects.remove(item.name) // abandoned temporary or partial transfer
                report.removedPartials += 1
            }
        }
        // Abandoned HTTP upload staging files.
        let uploads = URL(fileURLWithPath: configuration.stateDirectory).appendingPathComponent("uploads")
        for file in (try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified.timeIntervalSince1970 < cutoff {
                try? FileManager.default.removeItem(at: file)
                report.removedPartials += 1
            }
        }
        return report
    }
}
