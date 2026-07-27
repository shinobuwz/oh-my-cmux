import Foundation
import Testing
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focused coverage for `GitDiffSnapshotStore`'s process composition: the store
/// must run git through an injected ``CommandRunning`` with a finite deadline,
/// enforce a single in-flight scan, apply results only to the generation that
/// started them, cancel the scan + poll on stop/hidden/not-diff/deinit, refresh
/// immediately when the visible Diff resumes, and surface timeout/failure as a
/// retryable error (not a stuck loading state).
@MainActor
@Suite(.serialized)
struct SidebarGitProcessCompositionTests {

    // MARK: - Visibility lifecycle

    @Test func visibleStartsImmediateScanAndAppliesResult() async {
        let runner = CannedGitRunner(result: Self.statusOutput(" M file-a.txt\0"))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()

        await Self.waitFor { !store.isLoading && !store.files.isEmpty }

        #expect(store.files.count == 1)
        #expect(store.files.first?.path == "file-a.txt")
        #expect(store.files.first?.status == .modified)
        #expect(store.isGitRepository)
        #expect(store.errorMessage == nil)
        #expect(await runner.invocations == 1)

        store.stop()
    }

    @Test func hiddenDoesNotScan() async {
        let runner = CannedGitRunner(result: Self.statusOutput(" M file-a.txt\0"))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        // Directory is set but the panel is never made visible (no `start`),
        // so no git process should be spawned and no loading state surfaced.
        store.setDirectory("/repo")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.files.isEmpty)
        #expect(!store.isGitRepository)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
        #expect(await runner.invocations == 0)
    }

    @Test func stopWhileVisibleClearsLoadingSoPanelIsNeverStuck() async {
        let runner = GatedGitRunner(result: Self.statusOutput(" M file-a.txt\0"))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()
        // Wait for the in-flight scan to actually reach the runner (gated there).
        await Self.waitFor { await runner.invocations >= 1 }
        #expect(store.isLoading)

        store.stop()

        #expect(!store.isLoading)
        // Releasing the late command must not flip loading back on.
        await runner.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!store.isLoading)
    }

    // MARK: - Cancellation

    @Test func stopCancelsInFlightScanAndAppliesNoStaleResult() async {
        let runner = GatedGitRunner(result: Self.statusOutput(" M file-a.txt\0"))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()
        await Self.waitFor { await runner.invocations >= 1 }

        store.stop()

        // The gated command eventually returns; its result must be discarded
        // because the scan was cancelled (isActive == false) — never applied.
        await runner.release()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.files.isEmpty)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    // MARK: - Generation-safe result application

    @Test func directoryChangeDropsStaleInFlightResult() async {
        let runner = GatedFirstGitRunner(
            first: Self.statusOutput(" M stale.txt\0"),
            rest: Self.statusOutput(" M fresh.txt\0")
        )
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo-a")
        store.start()
        // First scan is held in flight at the runner.
        await Self.waitFor { await runner.invocations >= 1 }

        // Switching the directory bumps revision/generation and starts a new scan
        // for /repo-b that completes immediately with "fresh.txt".
        store.setDirectory("/repo-b")
        await Self.waitFor { !store.isLoading && !store.files.isEmpty }

        // Now release the stale /repo-a scan; it must not overwrite the fresh result.
        await runner.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.files.count == 1)
        #expect(store.files.first?.path == "fresh.txt")
        #expect(store.errorMessage == nil)

        store.stop()
    }

    // MARK: - Timeout / error surfacing

    @Test func timeoutClearsLoadingAndExposesRetryableError() async {
        let runner = CannedGitRunner(result: CommandResult(
            stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil
        ))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 1)

        store.setDirectory("/repo")
        store.start()
        await Self.waitFor { !store.isLoading }

        #expect(store.errorMessage != nil)
        #expect(!store.isLoading)
        #expect(store.files.isEmpty)

        store.stop()
    }

    @Test func nonZeroExitClearsLoadingAndExposesRetryableError() async {
        let runner = CannedGitRunner(result: CommandResult(
            stdout: "", stderr: "fatal: bad revision", exitStatus: 1,
            timedOut: false, executionError: nil
        ))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()
        await Self.waitFor { !store.isLoading && store.errorMessage != nil }

        #expect(store.errorMessage == "fatal: bad revision")
        #expect(!store.isLoading)
        #expect(store.files.isEmpty)

        store.stop()
    }

    @Test func launchFailureClearsLoadingAndExposesRetryableError() async {
        let runner = CannedGitRunner(result: CommandResult(
            stdout: nil, stderr: nil, exitStatus: nil, timedOut: false,
            executionError: "could not spawn git"
        ))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()
        await Self.waitFor { !store.isLoading && store.errorMessage != nil }

        #expect(store.errorMessage == "could not spawn git")
        #expect(!store.isLoading)
        #expect(store.files.isEmpty)

        store.stop()
    }

    @Test func notARepositoryShowsNoErrorAndNoLoading() async {
        let runner = CannedGitRunner(result: CommandResult(
            stdout: "", stderr: "fatal: not a git repository", exitStatus: 128,
            timedOut: false, executionError: nil
        ))
        let store = GitDiffSnapshotStore(commands: runner, pollInterval: .seconds(60), scanTimeout: 10)

        store.setDirectory("/repo")
        store.start()
        await Self.waitFor { !store.isLoading }

        #expect(!store.isGitRepository)
        #expect(store.errorMessage == nil)
        #expect(store.files.isEmpty)
        #expect(!store.isLoading)

        store.stop()
    }

    // MARK: - Helpers

    /// Builds a clean `git status --porcelain=v1 -z` stdout for one modified file.
    private static func statusOutput(_ raw: String) -> CommandResult {
        CommandResult(
            stdout: raw,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    /// Waits up to ~2s for `condition` to hold, yielding between checks so the
    /// store's @MainActor scan tasks can apply their results. Bounded
    /// wait-for-condition (not a poll-as-synchronization pattern); the condition
    /// is the actual completion signal being asserted.
    private static func waitFor(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - CommandRunning fakes

/// Returns a canned ``CommandResult`` for every invocation and records the count.
private actor CannedGitRunner: CommandRunning {
    private let result: CommandResult
    private(set) var invocations = 0

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations += 1
        return result
    }
}

/// Gates every invocation until ``release()`` is called. Used to hold a single
/// scan in flight so cancellation/generation behavior can be exercised.
private actor GatedGitRunner: CommandRunning {
    private let result: CommandResult
    private(set) var invocations = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Gates only the first invocation until ``releaseFirst()``; later calls return
/// `rest` immediately. Stages an in-flight first scan against a fast follow-up.
private actor GatedFirstGitRunner: CommandRunning {
    private let first: CommandResult
    private let rest: CommandResult
    private(set) var invocations = 0
    private var firstAnswered = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(first: CommandResult, rest: CommandResult) {
        self.first = first
        self.rest = rest
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations += 1
        if !firstAnswered {
            firstAnswered = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation = continuation
            }
            return first
        }
        return rest
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}
