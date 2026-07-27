import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

/// A deterministic fake ``WorkspaceGitMetadataWatcherSource`` with no real
/// filesystem dependency. The test controls exactly when events fire by
/// calling ``emit(_:)``; the registry pumps them to subscribers.
private actor FakeWorkspaceGitMetadataWatcherSource: WorkspaceGitMetadataWatcherSource {
    nonisolated let events: AsyncStream<WorkspaceGitMetadataWatcherEvent>
    private let continuation: AsyncStream<WorkspaceGitMetadataWatcherEvent>.Continuation
    private(set) var stopCount = 0
    private let suspendStop: Bool
    private var stopGate: CheckedContinuation<Void, Never>?
    private(set) var isStopSuspended = false

    init(suspendStop: Bool = false) {
        let (events, continuation) = AsyncStream<WorkspaceGitMetadataWatcherEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.suspendStop = suspendStop
    }

    func emit(_ event: WorkspaceGitMetadataWatcherEvent) {
        continuation.yield(event)
    }

    func stop() async {
        stopCount += 1
        if suspendStop {
            isStopSuspended = true
            await withCheckedContinuation { continuation in
                stopGate = continuation
            }
            isStopSuspended = false
        }
        continuation.finish()
    }

    func resumeStop() {
        stopGate?.resume()
        stopGate = nil
    }
}

/// Thread-safe factory that records every source it creates so tests can
/// access them to emit events. The `makeSource` closure is `@Sendable`
/// because the class is `@unchecked Sendable` with internal locking.
private final class FakeSourceFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [FakeWorkspaceGitMetadataWatcherSource] = []
    private let suspendFirstStop: Bool

    init(suspendFirstStop: Bool = false) {
        self.suspendFirstStop = suspendFirstStop
    }

    func makeSource(paths: [String]) -> (any WorkspaceGitMetadataWatcherSource)? {
        lock.lock()
        let source = FakeWorkspaceGitMetadataWatcherSource(
            suspendStop: suspendFirstStop && sources.isEmpty
        )
        sources.append(source)
        lock.unlock()
        return source
    }

    var allSources: [FakeWorkspaceGitMetadataWatcherSource] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }
}

private final class BlockingSourceFactory: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    let source = FakeWorkspaceGitMetadataWatcherSource()

    func makeSource(paths: [String]) -> (any WorkspaceGitMetadataWatcherSource)? {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
        return source
    }

    var didEnter: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func unblock() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A small yield-based poll helper (no sleeps). Returns `true` as soon as
/// `predicate` holds, `false` if the budget is exhausted.
private func waitUntil(maxYields: Int = 10_000, _ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<maxYields {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

@Suite struct WorkspaceGitMetadataWatcherRegistryTests {
    // MARK: Same-set sharing

    @Test(.timeLimit(.minutes(1)))
    func sameSetSharesOneSource() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub1 = try #require(await registry.subscribe(paths: ["/repo/.git/index", "/repo/.git/HEAD"]))
        let sub2 = try #require(await registry.subscribe(paths: ["/repo/.git/HEAD", "/repo/.git/index"]))

        // One entry, two subscriptions (order-independent normalization).
        #expect(await registry.entryCount == 1)
        #expect(await registry.subscriptionCount == 2)

        let entries = await registry.entries
        #expect(entries.count == 1)
        #expect(entries.first?.subscriptionCount == 2)
        #expect(entries.first?.watchedPaths == ["/repo/.git/HEAD", "/repo/.git/index"])

        // Exactly one source was created.
        #expect(factory.allSources.count == 1)

        await registry.release(sub1.token)
        await registry.release(sub2.token)
        await registry.waitUntilIdle()
    }

    // MARK: Fan-out

    @Test(.timeLimit(.minutes(1)))
    func fanOutDeliversEveryEventToEverySubscriber() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub1 = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        let sub2 = try #require(await registry.subscribe(paths: ["/repo/.git"]))

        // Drain both streams concurrently.
        actor Collector {
            var events: [WorkspaceGitMetadataWatcherEvent] = []
            func append(_ e: WorkspaceGitMetadataWatcherEvent) { events.append(e) }
        }
        let c1 = Collector()
        let c2 = Collector()

        let task1 = Task { @MainActor in
            for await event in sub1.events { await c1.append(event) }
        }
        let task2 = Task { @MainActor in
            for await event in sub2.events { await c2.append(event) }
        }

        let source = try #require(factory.allSources.first)
        await source.emit(WorkspaceGitMetadataWatcherEvent(changedPaths: ["/repo/.git/index"]))
        await source.emit(WorkspaceGitMetadataWatcherEvent(changedPaths: ["/repo/.git/HEAD"]))
        let received = await waitUntil(maxYields: 50_000) {
            let n1 = await c1.events.count
            let n2 = await c2.events.count
            return n1 == 2 && n2 == 2
        }
        #expect(received)
        let count1 = await c1.events.count
        let count2 = await c2.events.count
        #expect(count1 == 2)
        #expect(count2 == 2)
        let e1c1 = await c1.events[0]
        let e2c1 = await c1.events[1]
        let e1c2 = await c2.events[0]
        let e2c2 = await c2.events[1]
        #expect(e1c1.changedPaths == ["/repo/.git/index"])
        #expect(e2c1.changedPaths == ["/repo/.git/HEAD"])
        #expect(e1c2.changedPaths == ["/repo/.git/index"])
        #expect(e2c2.changedPaths == ["/repo/.git/HEAD"])

        task1.cancel()
        task2.cancel()
        await registry.release(sub1.token)
        await registry.release(sub2.token)
        await registry.waitUntilIdle()
    }

    // MARK: One release

    @Test(.timeLimit(.minutes(1)))
    func oneReleaseKeepsEntryForRemainingSubscriber() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub1 = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        let sub2 = try #require(await registry.subscribe(paths: ["/repo/.git"]))

        await registry.release(sub1.token)

        // Entry survives with one subscriber.
        #expect(await registry.entryCount == 1)
        #expect(await registry.subscriptionCount == 1)

        // The remaining subscriber still receives events.
        actor Collector {
            var events: [WorkspaceGitMetadataWatcherEvent] = []
            func append(_ e: WorkspaceGitMetadataWatcherEvent) { events.append(e) }
        }
        let collector = Collector()
        let task = Task { @MainActor in
            for await event in sub2.events { await collector.append(event) }
        }

        let source = try #require(factory.allSources.first)
        await source.emit(WorkspaceGitMetadataWatcherEvent(changedPaths: ["/repo/.git/index"]))
        let received = await waitUntil { await collector.events.count == 1 }
        #expect(received)

        task.cancel()
        await registry.release(sub2.token)
        await registry.waitUntilIdle()
    }

    // MARK: Last release

    @Test(.timeLimit(.minutes(1)))
    func lastReleaseStopsSourceAndRemovesEntry() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        let source = try #require(factory.allSources.first)

        await registry.release(sub.token)

        #expect(await registry.entryCount == 0)
        #expect(await registry.subscriptionCount == 0)
        #expect(await source.stopCount == 1)
    }

    // MARK: Distinct sets

    @Test(.timeLimit(.minutes(1)))
    func distinctSetsCreateSeparateEntries() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub1 = try #require(await registry.subscribe(paths: ["/repo-a/.git"]))
        let sub2 = try #require(await registry.subscribe(paths: ["/repo-b/.git"]))

        #expect(await registry.entryCount == 2)
        #expect(await registry.subscriptionCount == 2)
        #expect(factory.allSources.count == 2)

        await registry.release(sub1.token)
        #expect(await registry.entryCount == 1)
        #expect(await registry.subscriptionCount == 1)

        await registry.release(sub2.token)
        #expect(await registry.entryCount == 0)
        #expect(await registry.subscriptionCount == 0)
    }

    // MARK: Idle wait with deferred release

    @Test(.timeLimit(.minutes(1)))
    func waitUntilIdleReturnsAfterDeferredRelease() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        #expect(await registry.entryCount == 1)

        // Deferred release (matches the service's stop/deinit pattern: the
        // caller cannot await because it is on a synchronous @MainActor stop
        // path). waitUntilIdle must suspend until the deferred release drains.
        Task { await registry.release(sub.token) }

        await registry.waitUntilIdle()
        #expect(await registry.entryCount == 0)
        #expect(await registry.subscriptionCount == 0)
    }

    // MARK: Replacement generation isolation

    @Test(.timeLimit(.minutes(1)))
    func retiredPumpCannotFinishSuccessorSubscriptionForSamePathSet() async throws {
        let factory = FakeSourceFactory(suspendFirstStop: true)
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)
        let paths = ["/repo/.git"]

        let retired = try #require(await registry.subscribe(paths: paths))
        let retiredSource = try #require(factory.allSources.first)
        let releaseTask = Task { await registry.release(retired.token) }
        let stopSuspended = await waitUntil {
            await retiredSource.isStopSuspended
        }
        #expect(stopSuspended)

        let successor = try #require(await registry.subscribe(paths: paths))
        let successorSource = try #require(factory.allSources.last)
        #expect(factory.allSources.count == 2)
        #expect(await registry.entryCount == 1)
        #expect(await registry.subscriptionCount == 1)

        actor Collector {
            var events: [WorkspaceGitMetadataWatcherEvent] = []
            func append(_ event: WorkspaceGitMetadataWatcherEvent) { events.append(event) }
        }
        let collector = Collector()
        let listener = Task {
            for await event in successor.events {
                await collector.append(event)
            }
        }

        await retiredSource.resumeStop()
        await releaseTask.value
        await successorSource.emit(WorkspaceGitMetadataWatcherEvent(changedPaths: ["/repo/.git/index"]))

        let successorReceivedEvent = await waitUntil {
            await collector.events.count == 1
        }
        #expect(successorReceivedEvent)
        #expect(await registry.entryCount == 1)
        #expect(await registry.subscriptionCount == 1)

        listener.cancel()
        await registry.release(successor.token)
        await registry.waitUntilIdle()
    }

    // MARK: Service teardown during subscription creation

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func serviceDeallocationReleasesSubscriptionCreatedByPendingRequest() async throws {
        let fileManager = FileManager.default
        let repositoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-watcher-teardown-\(UUID().uuidString)", isDirectory: true)
        let gitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        try fileManager.createDirectory(at: gitURL, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: gitURL.appendingPathComponent("HEAD"))
        defer { try? fileManager.removeItem(at: repositoryURL) }

        let factory = BlockingSourceFactory()
        defer { factory.unblock() }
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)
        let host = RecordingSidebarGitHost()
        let (workspaceID, panelID) = host.addWorkspace(panelDirectory: repositoryURL.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceID, panelId: panelID)
        var service: SidebarGitMetadataService? = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .nonRepository),
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            registry: registry
        )
        service?.attach(host: host)
        service?.workspaceGitTrackedDirectoryByKey[key] = repositoryURL.path
        service?.updateWorkspaceGitMetadataWatcher(for: key, directory: repositoryURL.path)

        var subscribeStarted = false
        for _ in 0..<10_000 {
            if factory.didEnter {
                subscribeStarted = true
                break
            }
            await Task.yield()
        }
        #expect(subscribeStarted)
        weak let weakService = service
        service = nil
        #expect(weakService == nil)

        factory.unblock()
        var subscriptionReleased = false
        for _ in 0..<50_000 {
            if await factory.source.stopCount == 1 {
                subscriptionReleased = true
                break
            }
            await Task.yield()
        }
        #expect(subscriptionReleased)
        await registry.waitUntilIdle()
        #expect(await registry.entryCount == 0)
        #expect(await registry.subscriptionCount == 0)
    }

    // MARK: Source factory failure

    @Test(.timeLimit(.minutes(1)))
    func sourceFactoryReturningNilProducesNoEntry() async throws {
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: { _ in nil })

        let result = await registry.subscribe(paths: ["/repo/.git"])
        #expect(result == nil)
        #expect(await registry.entryCount == 0)
        #expect(await registry.subscriptionCount == 0)
    }

    // MARK: Idempotent release

    @Test(.timeLimit(.minutes(1)))
    func releaseIsIdempotent() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        await registry.release(sub.token)
        // Releasing the same token again is a silent no-op.
        await registry.release(sub.token)

        #expect(await registry.entryCount == 0)
        let source = try #require(factory.allSources.first)
        #expect(await source.stopCount == 1)
    }

    // MARK: Pump cancellation on release

    @Test(.timeLimit(.minutes(1)))
    func releaseCancelsPumpAndStopsSource() async throws {
        let factory = FakeSourceFactory()
        let registry = WorkspaceGitMetadataWatcherRegistry(sourceFactory: factory.makeSource)

        let sub = try #require(await registry.subscribe(paths: ["/repo/.git"]))
        let source = try #require(factory.allSources.first)

        // Release the last subscriber: the entry is removed, the pump task
        // is cancelled, and the source is stopped exactly once.
        await registry.release(sub.token)

        #expect(await registry.entryCount == 0)
        #expect(await source.stopCount == 1)

        // Emitting after the source was stopped (its continuation finished)
        // is a silent no-op — no late delivery, no crash, no hang. The pump
        // task has been cancelled, so even if a buffered event somehow
        // remained it would not be fanned out to a finished subscriber.
        await source.emit(WorkspaceGitMetadataWatcherEvent(changedPaths: ["/late"]))
        #expect(await source.stopCount == 1)
        #expect(await registry.entryCount == 0)
    }
}
