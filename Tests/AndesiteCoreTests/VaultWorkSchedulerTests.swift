import Foundation
import Testing
@testable import AndesiteCore

@Test func schedulerCoalescesBurstsAndRunsPeriodicScans() {
    var queue = VaultWorkScheduler(now: 0, debounce: 0.4,
                                   maximumCoalescing: 2, fallbackRescan: 300,
                                   snapshotTick: 15, retryDelay: 1)
    queue.reconciled(at: 0)
    #expect(queue.next(at: 0) == nil)
    for i in 0..<1000 {
        queue.observedChange(at: 0.1 + Double(i) * 0.001)
    }
    #expect(queue.pendingJobs == 1)
    #expect(!queue.indexedReadable)
    #expect(queue.next(at: 1.4) == nil)
    #expect(queue.next(at: 1.6) == .reconcile(.event))
    queue.reconciled(at: 1.6)
    #expect(queue.indexedReadable)
    #expect(queue.next(at: 1.7) == nil)
    #expect(queue.next(at: 15) == .snapshots)
    queue.snapshotsFinished(at: 15)
    // Periodic recovery scans run even if no event was observed.
    #expect(queue.next(at: 301.6) == .reconcile(.periodic))
}

@Test func schedulerBoundsLatencyAndHonorsRetryBackoff() {
    var queue = VaultWorkScheduler(now: 0, debounce: 0.5,
                                   maximumCoalescing: 2, fallbackRescan: 500,
                                   snapshotTick: 50, retryDelay: 1)
    queue.reconciled(at: 0)
    for i in 0...20 { queue.observedChange(at: Double(i) * 0.1) }
    // Even with continuing writes, the hard upper coalescing bound applies.
    #expect(queue.next(at: 1.5) == nil)
    #expect(queue.next(at: 2.01) == .reconcile(.event))
    #expect(queue.scanFailed(at: 2.01) == 1)
    #expect(!queue.indexedReadable)
    #expect(queue.next(at: 2.2) == nil)
    #expect(queue.next(at: 3.1) == .reconcile(.event))
    #expect(queue.scanFailed(at: 3.1) == 2)
    #expect(queue.next(at: 4.2) == nil)
    #expect(queue.next(at: 5.2) == .reconcile(.event))
    queue.reconciled(at: 5.2)
    #expect(queue.indexedReadable)
    #expect(queue.next(at: 5.2) == nil)
}
