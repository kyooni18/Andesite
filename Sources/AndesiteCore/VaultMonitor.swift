import Foundation
import CAndesiteFS

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
}

public enum VaultMonitorError: Error, Equatable {
    case invalidSettings
    case cannotStartStream(Int32)
}

/// One tick of Vault monitoring, run on the session's owner queue. Native
/// filesystem events are only hints that something changed; the scanner
/// decides what. Without native events, periodic rescans still run.
final class VaultWatcher {
    private let runtime: VaultRuntime
    private let report: (String) -> Void
    private var scheduler: VaultWorkScheduler
    private let events: FileEvents?
    private var lastGeneration: UInt64 = 0

    init(runtime: VaultRuntime, vaultDirectory: String, settings: VaultMonitorSettings,
         report: @escaping (String) -> Void) throws {
        guard [settings.latency, settings.debounce, settings.maximumCoalescing, settings.fallbackRescan,
               settings.snapshotTick, settings.polling, settings.retryDelay].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 86_400 }),
              settings.maximumCoalescing >= settings.debounce else { throw VaultMonitorError.invalidSettings }
        // Subscribe before the initial scan so no change can fall in between.
        events = try FileEvents(directory: vaultDirectory, latency: settings.latency)
        self.runtime = runtime
        self.report = report
        let now = ProcessInfo.processInfo.systemUptime
        scheduler = VaultWorkScheduler(now: now, debounce: settings.debounce,
                                       maximumCoalescing: settings.maximumCoalescing,
                                       fallbackRescan: events == nil ? min(settings.fallbackRescan, 2) : settings.fallbackRescan,
                                       snapshotTick: settings.snapshotTick, retryDelay: settings.retryDelay)
        do {
            let initial = try runtime.reconcile()
            scheduler.reconciled(at: ProcessInfo.processInfo.systemUptime)
            report("watch-ready discovered=\(initial.discovered) revisions=\(initial.revisionsCreated) snapshots=\(initial.snapshotsCreated)")
        } catch {
            _ = scheduler.scanFailed(at: now)
            report("watch-scan-failed attempt=1 error=\(error)")
        }
    }

    /// Runs at most one scheduled job.
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let events, let (generation, rescan) = events.drain(), generation != lastGeneration || rescan {
            lastGeneration = generation
            scheduler.observedChange(at: now)
            if rescan { report("watch-rescan-required") }
        }
        guard let job = scheduler.next(at: now) else { return }
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
        }
    }
}

/// The platform's native change notifications, reduced to "something
/// changed" (a generation counter) and "events were lost" (rescan).
final class FileEvents {
    #if os(macOS)
    private let stream: OpaquePointer

    init?(directory: String, latency: TimeInterval) throws {
        guard let stream = directory.withCString({ andesite_fsevents_start($0, latency) }) else {
            throw VaultMonitorError.cannotStartStream(errno)
        }
        self.stream = stream
    }

    deinit { andesite_fsevents_stop(stream) }

    func drain() -> (generation: UInt64, rescan: Bool)? {
        var result = andesite_fsevents_events()
        guard andesite_fsevents_drain(stream, &result) == 0 else { return nil }
        return (result.generation, result.recovery_flags != 0)
    }
    #elseif os(Linux)
    private let watch: OpaquePointer

    /// nil when inotify is unavailable (for example the watch limit is
    /// reached); the watcher then falls back to frequent periodic rescans.
    init?(directory: String, latency: TimeInterval) throws {
        guard let watch = andesite_inotify_start(directory) else { return nil }
        self.watch = watch
    }

    deinit { andesite_inotify_stop(watch) }

    func drain() -> (generation: UInt64, rescan: Bool)? {
        var generation: UInt64 = 0, rescan: UInt32 = 0
        guard andesite_inotify_drain(watch, &generation, &rescan) == 0 else { return (generation, true) }
        return (generation, rescan != 0)
    }
    #else
    init?(directory: String, latency: TimeInterval) throws { return nil }
    func drain() -> (generation: UInt64, rescan: Bool)? { nil }
    #endif
}
