import Foundation
import Testing

@testable import CmuxFoundation

/// A clock whose `sleep(for:)` suspends until the test releases it, so the
/// watcher's coalescing throttle can be advanced with no real waiting.
private actor GateClock: FileWatchClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleepers.append(continuation)
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Number of throttle delays currently parked on the clock.
    var sleeperCount: Int { sleepers.count }

    /// Suspends until at least one sleeper has registered.
    func waitForSleeper() async {
        if !sleepers.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiters.append(continuation)
        }
    }

    /// Releases the oldest parked throttle delay.
    func releaseOne() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }
}

@Suite(.serialized) struct RecursivePathWatcherTests {
    /// Creates a fresh temporary directory for a real-watcher test. Removing it
    /// during cleanup is the caller's `defer` responsibility.
    private static func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func emptyPathsFailsInitialization() {
        let watcher = RecursivePathWatcher(paths: [])
        #expect(watcher == nil)
    }

    @Test func realDirectoryStartsAndStops() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = RecursivePathWatcher(paths: [directory.path])
        #expect(watcher != nil)
        #expect(watcher?.watchedPaths == [directory.path])
        await watcher?.stop()
    }

    /// A burst of events inside one throttle window coalesces into a single
    /// yield, a fresh event re-arms the throttle, and `stop()` finishes the
    /// stream. This is the leading-edge behavior the watcher provides: react once
    /// per window during a storm, never once per event and never only after
    /// changes stop.
    @Test func burstCoalescesAndThrottleRearms() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        // Window 1: five events merge into one batch and preserve every path.
        for index in 0..<5 {
            await watcher.simulateFileSystemEventForTesting(RecursivePathWatcherEvent(
                changedPaths: ["/first/\(index)"],
                structurallyChangedPaths: index == 2 ? ["/first/2"] : [],
                requiresFullRescan: index == 4
            ))
        }
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)

        await clock.releaseOne()
        let first = await iterator.next()
        #expect(first?.changedPaths == Set((0..<5).map { "/first/\($0)" }))
        #expect(first?.structurallyChangedPaths == ["/first/2"])
        #expect(first?.requiresFullRescan == true)

        // Window 2: the throttle re-arms after the previous flush.
        for index in 0..<3 {
            await watcher.simulateFileSystemEventForTesting(RecursivePathWatcherEvent(
                changedPaths: ["/second/\(index)"]
            ))
        }
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)

        await clock.releaseOne()
        let second = await iterator.next()
        #expect(second?.changedPaths == Set((0..<3).map { "/second/\($0)" }))

        await watcher.stop()
        let afterStop: RecursivePathWatcherEvent? = await iterator.next()
        #expect(afterStop == nil)
    }

    /// Events delivered after `stop()` produce no further yields.
    @Test func eventsAfterStopAreIgnored() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.stop()
        await watcher.simulateFileSystemEventForTesting(RecursivePathWatcherEvent(changedPaths: ["/ignored"]))
        let next: RecursivePathWatcherEvent? = await iterator.next()
        #expect(next == nil)
        #expect(await clock.sleeperCount == 0)
    }

    /// A real watcher increments the process-global active-stream count exactly
    /// once on successful creation and decrements it again on `stop()`. The count
    /// is process-wide, so this suite is `.serialized` and every assertion is
    /// made against a per-test baseline rather than an absolute value.
    @Test func realWatcherIncrementsThenDecrementsGlobalCount() async {
        let directory = Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseline = RecursivePathWatcher.activeStreamCount
        let watcher = RecursivePathWatcher(paths: [directory.path])
        #expect(watcher != nil)
        #expect(RecursivePathWatcher.activeStreamCount == baseline + 1)

        await watcher?.stop()
        #expect(RecursivePathWatcher.activeStreamCount == baseline)
    }

    /// `stop()` is idempotent: a second stop and the deinit-time stop must not
    /// underflow the non-underflowing counter, so the count returns to baseline
    /// exactly once and stays there.
    @Test func repeatedStopIsIdempotentForGlobalCount() async {
        let directory = Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseline = RecursivePathWatcher.activeStreamCount
        guard let watcher = RecursivePathWatcher(paths: [directory.path]) else {
            Issue.record("watcher should initialize for a real directory")
            return
        }
        #expect(RecursivePathWatcher.activeStreamCount == baseline + 1)

        await watcher.stop()
        #expect(RecursivePathWatcher.activeStreamCount == baseline)
        await watcher.stop()
        #expect(RecursivePathWatcher.activeStreamCount == baseline)
    }

    /// Releasing the last strong reference without an explicit `stop()` runs
    /// `deinit`, which tears the `FSEventStream` down and restores the count —
    /// the cleanup path under test here.
    @Test func deinitDecrementsGlobalCountWhenWatcherIsReleased() async {
        let directory = Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseline = RecursivePathWatcher.activeStreamCount
        var watcher: RecursivePathWatcher? = RecursivePathWatcher(paths: [directory.path])
        #expect(watcher != nil)
        #expect(RecursivePathWatcher.activeStreamCount == baseline + 1)

        // Dropping the last strong reference forces deinit synchronously:
        // `eventStream.stop()` syncs onto the FSEvents queue, so the count is
        // restored by the time the assignment returns.
        watcher = nil
        #expect(RecursivePathWatcher.activeStreamCount == baseline)
    }
}
