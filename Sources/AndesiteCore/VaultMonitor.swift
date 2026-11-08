#if os(macOS)
import Foundation
import CAndesiteFS
import Darwin

public enum VaultMonitorError: Error, Equatable {
    case invalidSettings
    case cannotStartStream(Int32)
    case cannotReadStream(Int32)
    case watchedRootChanged
}

/// No callbacks can touch VaultRuntime: the native watcher only records event
/// generations and flags. Reconciliation, journals and snapshots stay on this
/// one synchronous owner thread. No FSEvents path is ever trusted.
public struct VaultMonitorSettings: Sendable {
    public var latency: TimeInterval
    public var debounce: TimeInterval
    public var maximumCoalescing: TimeInterval
    public var fallbackRescan: TimeInterval
    public var snapshotTick: TimeInterval
    public var polling: TimeInterval
    public var retryDelay: TimeInterval

    public init(latency: TimeInterval = 0.15, debounce: TimeInterval = 0.4,
                maximumCoalescing: TimeInterval = 2, fallbackRescan: TimeInterval = 300,
                snapshotTick: TimeInterval = 15, polling: TimeInterval = 0.1,
                retryDelay: TimeInterval = 1) {
        self.latency = latency
        self.debounce = debounce
        self.maximumCoalescing = maximumCoalescing
        self.fallbackRescan = fallbackRescan
        self.snapshotTick = snapshotTick
        self.polling = polling
        self.retryDelay = retryDelay
    }

    fileprivate func validate() throws {
        guard [latency, debounce, maximumCoalescing, fallbackRescan, snapshotTick, polling, retryDelay].allSatisfy({
            $0.isFinite && $0 > 0 && $0 <= 86_400
        }), maximumCoalescing >= debounce else { throw VaultMonitorError.invalidSettings }
    }
}

public final class VaultMonitor {
    private let runtime: VaultRuntime
    private let settings: VaultMonitorSettings
    private let stream: OpaquePointer

    /// Begin watching before the startup reconciliation, so the gap between
    /// subscribing and completing the first scan cannot suppress a later scan.
    public init(runtime: VaultRuntime, vaultDirectory: String,
                settings: VaultMonitorSettings = VaultMonitorSettings()) throws {
        try settings.validate()
        guard let stream = vaultDirectory.withCString({
            andesite_fsevents_start($0, settings.latency)
        }) else { throw VaultMonitorError.cannotStartStream(errno) }
        self.runtime = runtime
        self.settings = settings
        self.stream = stream
    }

    deinit { andesite_fsevents_stop(stream) }

    public static func installTerminationHandlers() {
        andesite_monitor_install_stop_handlers()
    }

    public static var stopRequested: Bool { andesite_monitor_stop_requested() != 0 }

    private func drain() throws -> andesite_fsevents_events {
        var result = andesite_fsevents_events()
        guard andesite_fsevents_drain(stream, &result) == 0 else {
            throw VaultMonitorError.cannotReadStream(errno)
        }
        if result.recovery_flags & 0x20 != 0 { // FSEvents rootChanged
            throw VaultMonitorError.watchedRootChanged
        }
        return result
    }

    /// Returns only after a requested stop. A transient unstable/invalid
    /// namespace is logged and retried; it never authorizes tombstones. SQLite,
    /// object-integrity or journal errors are also visible and cannot cause any
    /// automatic repair, conflict resolution or artifact retirement.
    public func run(shouldStop: () -> Bool = { VaultMonitor.stopRequested },
                    onIdle: (Bool) throws -> Void = { _ in },
                    report: (String) -> Void = { _ in }) throws {
        let initial = try runtime.reconcile()
        report("watch-ready discovered=\(initial.discovered) revisions=\(initial.revisionsCreated) snapshots=\(initial.snapshotsCreated)")
        var lastGeneration: UInt64 = 0
        var dirtySince: TimeInterval?
        var lastChange: TimeInterval = 0
        var nextAllowedScan: TimeInterval = 0
        var nextFallback = ProcessInfo.processInfo.systemUptime + settings.fallbackRescan
        var nextSnapshot = ProcessInfo.processInfo.systemUptime + settings.snapshotTick
        var consecutiveFailures = 0

        while !shouldStop() {
            let now = ProcessInfo.processInfo.systemUptime
            let events = try drain()
            if events.generation != lastGeneration {
                lastGeneration = events.generation
                if dirtySince == nil { dirtySince = now }
                lastChange = now
                if events.recovery_flags != 0 {
                    report("watch-rescan-required flags=0x\(String(events.recovery_flags, radix: 16)) eventID=\(events.last_event_id)")
                }
            } else if events.recovery_flags != 0 {
                // Even if generation saturates, recovery flags still force a scan.
                if dirtySince == nil { dirtySince = now }
                lastChange = now
                report("watch-rescan-required flags=0x\(String(events.recovery_flags, radix: 16))")
            }

            let eventDue = dirtySince.map {
                now - lastChange >= settings.debounce || now - $0 >= settings.maximumCoalescing
            } ?? false
            let scheduledDue = now >= nextFallback
            if (eventDue || scheduledDue) && now >= nextAllowedScan {
                do {
                    let result = try runtime.reconcile()
                    report("watch-scan cause=\(scheduledDue ? "periodic" : "event") discovered=\(result.discovered) revisions=\(result.revisionsCreated) deleted=\(result.deleted) renamed=\(result.renamed) snapshots=\(result.snapshotsCreated)")
                    consecutiveFailures = 0
                    dirtySince = nil
                    nextAllowedScan = 0
                    nextFallback = ProcessInfo.processInfo.systemUptime + settings.fallbackRescan
                    // Events arriving during reconciliation remain in the C
                    // generation and are consumed by the next loop iteration.
                } catch {
                    // No fallback to a stale index, inferred deletion or
                    // automatic journal action. Retain dirty work for retry.
                    consecutiveFailures += 1
                    report("watch-scan-failed attempt=\(consecutiveFailures) error=\(error)")
                    if dirtySince == nil { dirtySince = now }
                    lastChange = now - settings.debounce
                    nextAllowedScan = now + min(30, settings.retryDelay * Double(min(consecutiveFailures, 30)))
                    nextFallback = nextAllowedScan
                }
            }

            if now >= nextSnapshot {
                do {
                    let n = try runtime.scheduleDueSnapshots()
                    if n > 0 { report("watch-snapshots-created count=\(n)") }
                } catch {
                    report("watch-snapshot-schedule-failed error=\(error)")
                }
                nextSnapshot = ProcessInfo.processInfo.systemUptime + settings.snapshotTick
            }
            // HTTP is polled on this same thread, after all due reconciliation
            // work. Never expose the indexed view while a dirty/rescan hint
            // remains unresolved. The HTTP transport owns no SQLite handle.
            try onIdle(dirtySince == nil)
            Thread.sleep(forTimeInterval: settings.polling)
        }
        report("watch-stopping")
    }
}
#endif
