import Foundation

/// The watcher's timing: when a scan or snapshot pass is due. Bursts of
/// events coalesce into one scan (after `debounce` of quiet, at most
/// `maximumCoalescing` after the first event); failures back off; a
/// fallback rescan runs periodically. The watcher's work is background
/// work: `VaultExecutor` runs it only when no user request is waiting.
public enum VaultScheduledWork: Equatable, Sendable {
    case reconcile(VaultScanCause)
    case snapshots
}

public enum VaultScanCause: Equatable, Sendable {
    case event
    case periodic
}

public struct VaultWorkScheduler: Sendable {
    private let debounce: TimeInterval
    private let maximumCoalescing: TimeInterval
    private let fallbackRescan: TimeInterval
    private let snapshotTick: TimeInterval
    private let retryDelay: TimeInterval

    private var dirtySince: TimeInterval?
    private var lastChange: TimeInterval = 0
    private var nextScanAllowed: TimeInterval = 0
    private var nextPeriodicScan: TimeInterval
    private var nextSnapshot: TimeInterval
    private var failures = 0

    public init(now: TimeInterval, debounce: TimeInterval = 0.4,
                maximumCoalescing: TimeInterval = 2,
                fallbackRescan: TimeInterval = 300,
                snapshotTick: TimeInterval = 15,
                retryDelay: TimeInterval = 1) {
        self.debounce = debounce
        self.maximumCoalescing = maximumCoalescing
        self.fallbackRescan = fallbackRescan
        self.snapshotTick = snapshotTick
        self.retryDelay = retryDelay
        self.nextPeriodicScan = now + fallbackRescan
        self.nextSnapshot = now + snapshotTick
    }

    /// Coalesces potentially thousands of path-less FSEvents generations.
    /// The first observation defines a hard upper bound on debounce latency.
    public mutating func observedChange(at now: TimeInterval) {
        if dirtySince == nil { dirtySince = now }
        lastChange = now
    }

    /// Makes a scan due now (at startup).
    public mutating func requestScan(at now: TimeInterval) {
        if dirtySince == nil { dirtySince = now }
        lastChange = now - debounce
    }

    public mutating func reconciled(at now: TimeInterval) {
        dirtySince = nil
        failures = 0
        nextScanAllowed = 0
        nextPeriodicScan = now + fallbackRescan
    }

    public mutating func scanFailed(at now: TimeInterval) -> Int {
        failures += 1
        if dirtySince == nil { dirtySince = now - debounce }
        lastChange = now - debounce
        nextScanAllowed = now + min(30, retryDelay * Double(min(failures, 30)))
        // Keep the original periodic deadline; a retry of an observed
        // change remains an event-priority scan, not a new periodic scan.
        return failures
    }

    public mutating func snapshotsFinished(at now: TimeInterval) {
        nextSnapshot = now + snapshotTick
    }

    /// Whether no observed change is awaiting reconciliation.
    public var indexedReadable: Bool { dirtySince == nil }

    public var pendingJobs: Int { dirtySince != nil ? 1 : 0 }

    public func next(at now: TimeInterval) -> VaultScheduledWork? {
        let eventDue = dirtySince.map {
            now - lastChange >= debounce || now - $0 >= maximumCoalescing
        } ?? false
        let periodicDue = now >= nextPeriodicScan
        if (eventDue || periodicDue) && now >= nextScanAllowed {
            return .reconcile(periodicDue ? .periodic : .event)
        }
        if now >= nextSnapshot {
            return .snapshots
        }
        return nil
    }
}
