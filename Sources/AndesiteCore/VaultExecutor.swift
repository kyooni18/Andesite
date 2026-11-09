import Foundation

/// The kind of a call, which decides when it runs on the vault's thread.
public enum VaultWork: Sendable {
    /// A user-facing request that only reads. It runs before background
    /// work and is also served in the pauses of a long background scan.
    /// The catalog rejects writes made from it.
    case read
    /// A user-facing request that may change the vault. It runs before
    /// background work, and also between the batches of a scan.
    case write
    /// Work nobody waits on interactively: scans, sync, garbage collection.
    /// It runs when no user request is waiting, and lets waiting requests
    /// in at safe points.
    case background
}

/// How background work lets waiting user requests in. The runtime calls
/// these only outside transactions, passing whether writes may enter at
/// that point (reads always may). A runtime used directly never yields.
struct Cooperation {
    /// Whether a write is next in line (a scan then ends its batch early).
    var writeWaiting: () -> Bool = { false }
    /// Runs the waiting requests that may enter, in arrival order; returns
    /// whether one of them was a write.
    var yield: (_ writes: Bool) -> Bool = { _ in false }
    /// Waits, letting requests in as `yield` does; returns whether a write ran.
    var pause: (TimeInterval, _ writes: Bool) -> Bool = { seconds, _ in Thread.sleep(forTimeInterval: seconds); return false }
}

/// Holds a non-escaping closure for the duration of `VaultExecutor.run`.
private final class Borrowed<T> {
    var body: ((VaultRuntime) throws -> T)?
    init(_ body: @escaping (VaultRuntime) throws -> T) { self.body = body }
}

/// Runs everything that touches one vault on one thread, in this order:
///
/// 1. User requests (`.read`, `.write`), first come first served.
/// 2. Queued background work, then the watcher.
///
/// Background work that has waited `starvationLimit` runs next anyway, so
/// constant traffic cannot stall indexing. While background work runs,
/// waiting user requests enter at its safe points (see `Cooperation`), so
/// they wait for at most about one file's capture, not a whole scan.
final class VaultExecutor: @unchecked Sendable {
    private struct Job {
        let work: VaultWork
        let run: (VaultRuntime) -> Void
        let cancel: (Error) -> Void
    }

    private let runtime: VaultRuntime
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var user: [Job] = []
    private var background: [Job] = []
    private var stopped = false
    private var backgroundWaitingSince: TimeInterval?
    private var thread: Thread?
    // Executor thread only.
    private var watcher: VaultWatcher?
    private var nextTick: TimeInterval = 0

    static let starvationLimit: TimeInterval = 0.5

    init(runtime: VaultRuntime) {
        self.runtime = runtime
        let thread = Thread { [self] in main() }
        thread.name = "andesite.vault"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func submit<T>(_ work: VaultWork, _ body: @escaping (VaultRuntime) throws -> T,
                   completion: @escaping (Result<T, Error>) -> Void) {
        let job = Job(work: work, run: { runtime in completion(Result { try body(runtime) }) },
                      cancel: { completion(.failure($0)) })
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return completion(.failure(VaultRuntimeError.closed))
        }
        if work == .background { background.append(job) } else { user.append(job) }
        condition.signal()
        condition.unlock()
    }

    /// Runs `body` and waits for it. Must not be called from the vault's thread.
    func run<T>(_ work: VaultWork, _ body: (VaultRuntime) throws -> T) throws -> T {
        precondition(Thread.current !== thread, "Vault.run called from inside a vault call")
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        return try withoutActuallyEscaping(body) { body in
            // The executor keeps its job a moment after completing it; only
            // this box may outlive the call, never `body` itself.
            let box = Borrowed(body)
            submit(work, { try box.body!($0) }) { box.body = nil; result = $0; done.signal() }
            done.wait()
            return try result!.get()
        }
    }

    /// Installs or removes the watcher (on the vault's thread).
    func setWatcher(_ watcher: VaultWatcher?) {
        self.watcher = watcher
        nextTick = 0
    }

    /// Runs `body` as the last job; later submissions fail with `closed`.
    func close(_ body: @escaping (VaultRuntime) throws -> Void) throws {
        try run(.write) { runtime in
            defer {
                condition.lock()
                stopped = true
                let abandoned = user + background
                user = []; background = []
                condition.unlock()
                for job in abandoned { job.cancel(VaultRuntimeError.closed) }
            }
            watcher = nil
            try body(runtime)
        }
    }

    private func main() {
        while true {
            condition.lock()
            var job: Job?, tick = false
            while true {
                let now = Self.now
                let tickDue = watcher != nil && now >= nextTick
                if !background.isEmpty || tickDue {
                    if backgroundWaitingSince == nil { backgroundWaitingSince = now }
                } else { backgroundWaitingSince = nil }
                let starved = backgroundWaitingSince.map { now - $0 >= Self.starvationLimit } ?? false
                if !user.isEmpty && !starved { job = user.removeFirst(); break }
                if !background.isEmpty { job = background.removeFirst(); backgroundWaitingSince = nil; break }
                if tickDue { tick = true; backgroundWaitingSince = nil; break }
                if stopped { condition.unlock(); return }
                if watcher != nil { _ = condition.wait(until: Date(timeIntervalSinceNow: nextTick - now)) }
                else { condition.wait() }
            }
            condition.unlock()
            if let job {
                execute(job)
            } else if tick, let watcher {
                runtime.cooperation = cooperation()
                watcher.tick(runtime)
                runtime.cooperation = Cooperation()
                nextTick = Self.now + watcher.polling
            }
        }
    }

    private func execute(_ job: Job) {
        switch job.work {
        case .read: runtime.readingOnly { job.run(runtime) }
        case .write: job.run(runtime)
        case .background:
            runtime.cooperation = cooperation()
            job.run(runtime)
            runtime.cooperation = Cooperation()
        }
    }

    /// Runs waiting user requests nested inside background work.
    private func cooperation() -> Cooperation {
        func next(_ writes: Bool) -> Job? {
            condition.lock(); defer { condition.unlock() }
            guard let first = user.first, first.work == .read || writes else { return nil }
            return user.removeFirst()
        }
        func yield(_ writes: Bool) -> Bool {
            var wrote = false
            let saved = runtime.cooperation
            runtime.cooperation = Cooperation()
            while let job = next(writes) {
                if job.work == .read { runtime.readingOnly { job.run(runtime) } }
                else { job.run(runtime); wrote = true }
            }
            runtime.cooperation = saved
            return wrote
        }
        return Cooperation(
            writeWaiting: { [self] in
                condition.lock(); defer { condition.unlock() }
                return user.first.map { $0.work == .write } ?? false
            },
            yield: yield,
            pause: { [self] seconds, writes in
                let end = Self.now + seconds
                var wrote = false
                while true {
                    wrote = yield(writes) || wrote
                    let now = Self.now
                    guard now < end else { return wrote }
                    condition.lock()
                    _ = condition.wait(until: Date(timeIntervalSinceNow: end - now))
                    condition.unlock()
                }
            })
    }
}
