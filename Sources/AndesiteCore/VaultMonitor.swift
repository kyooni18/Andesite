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
        var scheduler = VaultWorkScheduler(
            now: ProcessInfo.processInfo.systemUptime,
            debounce: settings.debounce,
            maximumCoalescing: settings.maximumCoalescing,
            fallbackRescan: settings.fallbackRescan,
            snapshotTick: settings.snapshotTick,
            retryDelay: settings.retryDelay)
        scheduler.reconciled(at: ProcessInfo.processInfo.systemUptime)

        while !shouldStop() {
            let now = ProcessInfo.processInfo.systemUptime
            let events = try drain()
            if events.generation != lastGeneration || events.recovery_flags != 0 {
                lastGeneration = events.generation
                scheduler.observedChange(at: now)
                if events.recovery_flags != 0 {
                    report("watch-rescan-required flags=0x\(String(events.recovery_flags, radix: 16)) eventID=\(events.last_event_id)")
                }
            }

            if let job = scheduler.next(at: now) {
                switch job {
                case .reconcile(let cause):
                    do {
                        let result = try runtime.reconcile()
                        scheduler.reconciled(at: ProcessInfo.processInfo.systemUptime)
                        report("watch-scan cause=\(cause == .periodic ? "periodic" : "event") discovered=\(result.discovered) revisions=\(result.revisionsCreated) deleted=\(result.deleted) renamed=\(result.renamed) snapshots=\(result.snapshotsCreated)")
                    } catch {
                        let attempt = scheduler.scanFailed(at: ProcessInfo.processInfo.systemUptime)
                        report("watch-scan-failed attempt=\(attempt) error=\(error)")
                    }

                case .snapshots:
                    do {
                        let count = try runtime.scheduleDueSnapshots()
                        if count > 0 { report("watch-snapshots-created count=\(count)") }
                    } catch {
                        report("watch-snapshot-schedule-failed error=\(error)")
                    }
                    scheduler.snapshotsFinished(at: ProcessInfo.processInfo.systemUptime)

                case .refreshLinks:
                    do {
                        let result = try runtime.refreshLinkCache()
                        scheduler.refreshedLinks()
                        report("watch-link-cache generation=\(result.generation) parsed=\(result.parsedDocuments) reused=\(result.reusedDocuments) changed=\(result.graphChanged)")
                    } catch VaultLinkGraphError.graphTooLarge {
                        scheduler.refreshFailed(at: ProcessInfo.processInfo.systemUptime,
                                                retry: false)
                        report("watch-link-cache-unavailable reason=graphTooLarge")
                    } catch {
                        scheduler.refreshFailed(at: ProcessInfo.processInfo.systemUptime,
                                                retry: true)
                        report("watch-link-cache-failed error=\(error)")
                    }
                }
            }

            // An event can arrive while a scan or cache refresh executes.
            // Check the generation once more before serving any HTTP GET,
            // so newly pending changes invalidate indexed reads promptly.
            let afterWork = try drain()
            if afterWork.generation != lastGeneration || afterWork.recovery_flags != 0 {
                lastGeneration = afterWork.generation
                scheduler.observedChange(at: ProcessInfo.processInfo.systemUptime)
                if afterWork.recovery_flags != 0 {
                    report("watch-rescan-required flags=0x\(String(afterWork.recovery_flags, radix: 16)) eventID=\(afterWork.last_event_id)")
                }
            }

            // Only one scheduled operation runs per tick. The private HTTP
            // reader then services requests without a second SQLite owner.
            try onIdle(scheduler.indexedReadable)
            Thread.sleep(forTimeInterval: settings.polling)
        }
        report("watch-stopping")
    }
}
#endif
