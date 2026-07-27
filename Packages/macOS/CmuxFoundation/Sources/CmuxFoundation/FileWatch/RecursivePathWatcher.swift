import Foundation

/// Watches a set of filesystem paths recursively and reports coalesced batches
/// with the paths and structural-change information preserved.
///
/// Construct one with the paths to watch (the caller resolves which paths matter
/// for its domain) and consume ``events`` to react to changes:
///
/// ```swift
/// guard let watcher = RecursivePathWatcher(paths: paths) else { return }
/// let task = Task { @MainActor in
///     for await event in watcher.events { handle(event) }
/// }
/// // later: task.cancel(); await watcher.stop()
/// ```
///
/// **Coalescing.** A leading-edge throttle folds a burst into one yield: the
/// first event in a window arms a single bounded delay (``FileWatchClock``) and
/// events arriving while that delay is pending are folded into it. Combined with
/// the underlying `FSEventStream` latency, the worst-case delay from a change to
/// an ``events`` element is roughly twice the throttle interval. During a
/// sustained storm an element is yielded at most once per window — it does *not*
/// wait for changes to stop, which keeps reactions responsive without per-event
/// churn.
///
/// **Construction.** The `FSEventStream` is created synchronously in ``init``,
/// so the watcher is already listening when it returns (nothing is missed in the
/// gap a deferred start would open) and ``init`` fails (`nil`) if the stream
/// cannot be created. The stream's `@Sendable` sink forwards into a private
/// raw-event `AsyncStream` rather than capturing the actor, which is what lets
/// creation happen in-`init`; a single actor-isolated pump drains that raw stream
/// and applies the throttle. The pump's lifetime is the raw stream's: ``stop()``
/// and `deinit` finish it.
public actor RecursivePathWatcher {
    /// The paths this watcher observes, as passed to ``init(paths:clock:)``.
    ///
    /// Exposed so callers can compare against a freshly resolved set and skip
    /// recreating an equivalent watcher.
    public nonisolated let watchedPaths: [String]

    /// Stream of coalesced change batches. Each element unions every path and
    /// structural flag reported during one throttle window. Finishes when
    /// ``stop()`` is called or the watcher is deallocated.
    public nonisolated let events: AsyncStream<RecursivePathWatcherEvent>

    /// The process-wide count of currently active `FSEventStream` instances owned
    /// by `RecursivePathWatcher`.
    ///
    /// This is a production diagnostic, not a correctness gate: it reflects how
    /// many real filesystem event streams the process is keeping alive right now.
    /// Each successful watcher creation increments it exactly once; each `stop()`
    /// — or watcher deallocation — decrements it exactly once. The decrement is
    /// non-underflowing, so repeated stops and a `deinit` after an explicit stop
    /// never drive the count negative. A value that never returns to its baseline
    /// signals a watcher whose `FSEventStream` was started but never torn down.
    ///
    /// The value is a best-effort snapshot taken with relaxed atomic ordering; it
    /// is not bound to any isolation domain and may change between a read and its
    /// use.
    public nonisolated static var activeStreamCount: UInt64 {
        FileSystemEventStream.activeStreamCount
    }

    private let continuation: AsyncStream<RecursivePathWatcherEvent>.Continuation
    private let clock: any FileWatchClock
    // nil only for the test-throttle initializer, which drives the throttle
    // directly without a real FSEventStream.
    private let eventStream: FileSystemEventStream?
    // Finishing this ends the pump task (see init); raw FS events flow through it.
    private let rawContinuation: AsyncStream<RecursivePathWatcherEvent>.Continuation
    private var pendingEvent: RecursivePathWatcherEvent?
    private var throttleTask: Task<Void, Never>?
    private var isStopped = false

    /// The `FSEventStream` coalescing latency, in seconds.
    private static let streamLatency = 0.25
    /// The leading-edge throttle window. Combined with ``streamLatency`` the
    /// worst-case change-to-yield delay is roughly twice this.
    private static let throttleInterval: Duration = .milliseconds(250)

    /// Creates and starts a watcher for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - clock: The clock driving the coalescing throttle. Defaults to
    ///     ``SystemFileWatchClock``.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started. On success the stream is already
    ///   listening.
    public init?(
        paths: [String],
        clock: any FileWatchClock = SystemFileWatchClock()
    ) {
        guard !paths.isEmpty else { return nil }
        self.watchedPaths = paths
        self.clock = clock
        let (events, eventsContinuation) = AsyncStream<RecursivePathWatcherEvent>.makeStream()
        self.events = events
        self.continuation = eventsContinuation
        let (rawEvents, rawContinuation) = AsyncStream<RecursivePathWatcherEvent>.makeStream()
        self.rawContinuation = rawContinuation

        // The sink captures `rawContinuation` (a Sendable value), not `self`, so
        // the stream can be created synchronously here without escaping the
        // actor mid-init.
        guard let eventStream = FileSystemEventStream(
            paths: paths,
            latency: Self.streamLatency,
            onEvent: { event in rawContinuation.yield(event) }
        ) else {
            eventsContinuation.finish()
            rawContinuation.finish()
            return nil
        }
        self.eventStream = eventStream

        // Drain raw FS events through the actor-isolated throttle. Started last so
        // init touches no isolated state after `self` escapes into the task; it
        // holds `self` weakly and ends when `rawEvents` finishes (stop/deinit).
        Task { [weak self] in
            for await event in rawEvents {
                await self?.handleRawEvent(event)
            }
        }
    }

    /// Creates a watcher with no underlying `FSEventStream`, driven only by
    /// ``simulateFileSystemEventForTesting()``.
    ///
    /// Used by the package tests to exercise the coalescing throttle in isolation
    /// with an injected clock and no real filesystem dependency.
    init(testThrottleClock clock: any FileWatchClock) {
        self.watchedPaths = []
        self.clock = clock
        let (events, eventsContinuation) = AsyncStream<RecursivePathWatcherEvent>.makeStream()
        self.events = events
        self.continuation = eventsContinuation
        let (_, rawContinuation) = AsyncStream<RecursivePathWatcherEvent>.makeStream()
        self.rawContinuation = rawContinuation
        self.eventStream = nil
    }

    /// Stops the watcher, tears down the underlying stream, and finishes
    /// ``events``. Idempotent.
    public func stop() {
        isStopped = true
        throttleTask?.cancel()
        throttleTask = nil
        eventStream?.stop()
        rawContinuation.finish()
        continuation.finish()
    }

    deinit {
        // FSEventStream teardown is synchronous and thread-safe; finishing the
        // continuations ends the pump and any consumer.
        eventStream?.stop()
        throttleTask?.cancel()
        rawContinuation.finish()
        continuation.finish()
    }

    /// Leading-edge throttle entry point. Every event is merged into the pending
    /// batch; only the first event of a window arms the bounded delay.
    private func handleRawEvent(_ event: RecursivePathWatcherEvent) {
        guard !isStopped else { return }
        pendingEvent = pendingEvent?.merging(event) ?? event
        guard throttleTask == nil else { return }
        let clock = self.clock
        let interval = Self.throttleInterval
        throttleTask = Task { [weak self] in
            try? await clock.sleep(for: interval)
            await self?.flushThrottle()
        }
    }

    private func flushThrottle() {
        throttleTask = nil
        guard !isStopped, let event = pendingEvent else { return }
        pendingEvent = nil
        continuation.yield(event)
    }

    /// Feeds a synthetic filesystem event into the throttle. Test-only seam used
    /// by ``init(testThrottleClock:)``-constructed watchers.
    func simulateFileSystemEventForTesting(_ event: RecursivePathWatcherEvent) {
        handleRawEvent(event)
    }
}
