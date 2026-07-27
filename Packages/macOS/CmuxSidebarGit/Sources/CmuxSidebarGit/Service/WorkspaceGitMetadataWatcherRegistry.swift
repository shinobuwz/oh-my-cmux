public import Foundation
internal import CmuxFoundation

/// An opaque, `Sendable` handle representing one subscription to a shared
/// filesystem event source in ``WorkspaceGitMetadataWatcherRegistry``.
///
/// Pass it to ``WorkspaceGitMetadataWatcherRegistry/release(_:)`` when the
/// subscriber no longer needs events. Release is idempotent: a token may be
/// released any number of times.
public struct WorkspaceGitMetadataWatcherSubscriptionToken: Sendable, Hashable {
    let id: UUID
    let pathsKey: WorkspaceGitMetadataWatchedPathsKey

    init(id: UUID, pathsKey: WorkspaceGitMetadataWatchedPathsKey) {
        self.id = id
        self.pathsKey = pathsKey
    }
}

/// The result of a successful ``WorkspaceGitMetadataWatcherRegistry/subscribe``
/// call: a token to release later and an event stream to pump.
///
/// Both parts are ``Sendable`` — the token is a value type and
/// `AsyncStream` is `Sendable` when its element is — so the result may be
/// captured in a detached task or a `@MainActor` listener without crossing
/// isolation boundaries unsafely.
public struct WorkspaceGitMetadataWatcherSubscriptionResult: Sendable {
    /// The handle to pass to ``WorkspaceGitMetadataWatcherRegistry/release(_:)``
    /// when the subscriber is done.
    public let token: WorkspaceGitMetadataWatcherSubscriptionToken
    /// A stream of coalesced change batches for this subscription. Finishes
    /// when the token is released (or the underlying source stops).
    public let events: AsyncStream<WorkspaceGitMetadataWatcherEvent>
}

/// A debug-safe snapshot of one shared event source entry in the registry.
public struct WorkspaceGitMetadataWatcherRegistryEntrySnapshot: Sendable, Equatable {
    /// The normalized, sorted, de-duplicated path set this entry watches.
    public let watchedPaths: [String]
    /// How many live subscribers share this entry's event source.
    public let subscriptionCount: Int
}

/// A process-wide (or per-injection) registry that deduplicates filesystem
/// watchers by normalized exact full path set.
///
/// Each unique ``WorkspaceGitMetadataWatchedPathsKey`` is backed by at most
/// one event source (``WorkspaceGitMetadataWatcherSource``). Multiple
/// subscribers for the same path set share that single source: the registry
/// refcounts subscriptions, fans events out to every subscriber, and stops
/// the source when the last subscriber releases.
///
/// **Injection.** This is an injected actor, never a singleton.
/// ``SidebarGitMetadataService`` defaults to a fresh instance per service
/// (test compatibility); the app's composition root (``TabManager`` /
/// ``AppDelegate``) creates one shared instance and injects it into every
/// window's service so that windows observing the same repository share a
/// single `FSEventStream`.
///
/// **Threading.** An actor: every public method is isolated. The internal
/// pump task — one per entry — reads the source's event stream and fans out
/// to subscriber continuations. Subscribers pump their own per-subscription
/// `AsyncStream` from whatever actor they choose (typically `@MainActor`).
public actor WorkspaceGitMetadataWatcherRegistry {
    /// One registry entry: the shared event source, its fan-out pump, and
    /// every live subscriber's continuation keyed by subscription id.
    private final class Entry {
        let id: UUID
        let source: any WorkspaceGitMetadataWatcherSource
        let pumpTask: Task<Void, Never>
        var subscribers: [UUID: AsyncStream<WorkspaceGitMetadataWatcherEvent>.Continuation]

        init(
            id: UUID,
            source: any WorkspaceGitMetadataWatcherSource,
            pumpTask: Task<Void, Never>,
            subscribers: [UUID: AsyncStream<WorkspaceGitMetadataWatcherEvent>.Continuation] = [:]
        ) {
            self.id = id
            self.source = source
            self.pumpTask = pumpTask
            self.subscribers = subscribers
        }
    }

    private let sourceFactory: @Sendable ([String]) -> (any WorkspaceGitMetadataWatcherSource)?
    private var entriesByKey: [WorkspaceGitMetadataWatchedPathsKey: Entry] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a registry backed by the production
    /// ``RecursivePathWatcherSource`` (which wraps ``RecursivePathWatcher``).
    public init() {
        self.sourceFactory = { RecursivePathWatcherSource(paths: $0) }
    }

    /// Creates a registry backed by `sourceFactory`. Internal: used by tests
    /// to inject deterministic fake sources with no real filesystem dependency.
    init(sourceFactory: @escaping @Sendable ([String]) -> (any WorkspaceGitMetadataWatcherSource)?) {
        self.sourceFactory = sourceFactory
    }

    // MARK: Subscription lifecycle

    /// Subscribes to events for `paths`, sharing a single underlying source
    /// with every other subscriber for the same normalized path set.
    ///
    /// - Parameter paths: The files and directories to watch. Normalized
    ///   into a ``WorkspaceGitMetadataWatchedPathsKey`` (de-duplicated and
    ///   sorted) for sharing.
    /// - Returns: A subscription result (token + event stream), or `nil` if
    ///   the source factory could not create a source for these paths (for
    ///   example, `RecursivePathWatcher` rejected them).
    public func subscribe(
        paths: [String]
    ) -> WorkspaceGitMetadataWatcherSubscriptionResult? {
        let pathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: paths)

        if let entry = entriesByKey[pathsKey] {
            return addSubscriber(to: entry, pathsKey: pathsKey)
        }

        guard let source = sourceFactory(pathsKey.paths) else {
            return nil
        }

        let entryID = UUID()
        let entry = Entry(id: entryID, source: source, pumpTask: Task { [weak self] in
            await self?.runPump(pathsKey: pathsKey, entryID: entryID, events: source.events)
        })
        entriesByKey[pathsKey] = entry
        return addSubscriber(to: entry, pathsKey: pathsKey)
    }

    private func addSubscriber(
        to entry: Entry,
        pathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) -> WorkspaceGitMetadataWatcherSubscriptionResult {
        let id = UUID()
        let (events, continuation) = AsyncStream<WorkspaceGitMetadataWatcherEvent>.makeStream()
        entry.subscribers[id] = continuation
        return WorkspaceGitMetadataWatcherSubscriptionResult(
            token: WorkspaceGitMetadataWatcherSubscriptionToken(id: id, pathsKey: pathsKey),
            events: events
        )
    }

    /// Releases a subscription. Idempotent: releasing an already-released
    /// (or unknown) token is a silent no-op.
    ///
    /// Decrements the entry's refcount. When the last subscriber releases,
    /// the underlying source is stopped and the entry is removed.
    public func release(_ token: WorkspaceGitMetadataWatcherSubscriptionToken) async {
        guard let entry = entriesByKey[token.pathsKey] else { return }
        guard let continuation = entry.subscribers.removeValue(forKey: token.id) else { return }
        continuation.finish()

        guard entry.subscribers.isEmpty else {
            notifyIdleWaitersIfNeeded()
            return
        }

        entriesByKey.removeValue(forKey: token.pathsKey)
        entry.pumpTask.cancel()
        await entry.source.stop()
        notifyIdleWaitersIfNeeded()
    }

    // MARK: Pump (one per entry)

    /// Drains the source's event stream and fans every batch out to every
    /// subscriber continuation. Runs for the lifetime of the entry; exits
    /// when the source stream finishes (source stopped or deallocated) or
    /// when the pump task is cancelled (last subscriber released).
    ///
    /// This method is `async` and `for await`s the stream directly — the
    /// `Entry.pumpTask` wraps this call, so cancelling the pump task cancels
    /// the true stream consumer (not a fire-and-forget wrapper that has
    /// already returned).
    private func runPump(
        pathsKey: WorkspaceGitMetadataWatchedPathsKey,
        entryID: UUID,
        events: AsyncStream<WorkspaceGitMetadataWatcherEvent>
    ) async {
        for await event in events {
            if Task.isCancelled { break }
            fanOut(event, for: pathsKey, entryID: entryID)
        }
        finishSubscribers(for: pathsKey, entryID: entryID)
    }

    private func fanOut(
        _ event: WorkspaceGitMetadataWatcherEvent,
        for pathsKey: WorkspaceGitMetadataWatchedPathsKey,
        entryID: UUID
    ) {
        guard let entry = entriesByKey[pathsKey], entry.id == entryID else { return }
        for continuation in entry.subscribers.values {
            continuation.yield(event)
        }
    }

    /// Called when the source stream finishes on its own (e.g. the underlying
    /// watcher was deallocated externally). Finishes every subscriber
    /// continuation so their listener tasks exit and release their tokens.
    private func finishSubscribers(
        for pathsKey: WorkspaceGitMetadataWatchedPathsKey,
        entryID: UUID
    ) {
        guard let entry = entriesByKey[pathsKey], entry.id == entryID else { return }
        for continuation in entry.subscribers.values {
            continuation.finish()
        }
        // Do NOT remove the entry here: each subscriber's listener task will
        // exit (stream finished) and call release(), which removes the entry
        // when the last subscriber is gone. Clearing here would leak the
        // source (never stopped) and race with concurrent release() calls.
    }

    // MARK: Snapshots

    /// The number of shared event source entries currently alive.
    public var entryCount: Int { entriesByKey.count }

    /// The total number of live subscriptions across all entries.
    public var subscriptionCount: Int {
        entriesByKey.values.reduce(0) { $0 + $1.subscribers.count }
    }

    /// A debug-safe snapshot of every entry: its watched paths and how many
    /// subscribers share it.
    public var entries: [WorkspaceGitMetadataWatcherRegistryEntrySnapshot] {
        entriesByKey.map { key, entry in
            WorkspaceGitMetadataWatcherRegistryEntrySnapshot(
                watchedPaths: key.paths,
                subscriptionCount: entry.subscribers.count
            )
        }
        .sorted { $0.watchedPaths.lexicographicallyPrecedes($1.watchedPaths) }
    }

    // MARK: Deterministic idle wait (for tests)

    /// Suspends until the registry has zero entries and zero subscriptions.
    ///
    /// Returns immediately if already idle. Used by tests to deterministically
    /// wait for async release tasks (deferred from synchronous service stop /
    /// deinit) to drain.
    public func waitUntilIdle() async {
        guard !entriesByKey.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
        }
    }

    private func notifyIdleWaitersIfNeeded() {
        guard entriesByKey.isEmpty, !idleWaiters.isEmpty else { return }
        for waiter in idleWaiters { waiter.resume() }
        idleWaiters.removeAll()
    }
}
