import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GitWorktreeStoreTests {
    // MARK: Read-only GIT_OPTIONAL_LOCKS=0 vs mutating env

    @Test
    func addRepositoryResolvesRootViaNonLockingGit() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: "/repo",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        let added = await store.addRepository(path: "/repo")

        #expect(added)
        let calls = await runner.calls
        #expect(calls.contains { call in
            call.executable == "/usr/bin/env"
                && call.arguments == ["GIT_OPTIONAL_LOCKS=0", "git", "rev-parse", "--show-toplevel"]
        }, "rev-parse must run non-locking via /usr/bin/env GIT_OPTIONAL_LOCKS=0 git; got \(calls)")
        #expect(calls.allSatisfy { $0.timeout != nil })
    }

    @Test
    func createWorktreeRunsMutatingGitWithoutLockEnv() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        let destination = try await store.createWorktree(
            repositoryRoot: "/repo",
            branchName: "feature",
            destinationPath: "/repo-feature"
        )

        #expect(destination == "/repo-feature")
        let calls = await runner.calls
        #expect(calls.contains { call in
            call.executable == "git"
                && call.arguments == ["worktree", "add", "-b", "feature", "/repo-feature", "HEAD"]
        }, "worktree add must run mutating git directly; got \(calls)")
        #expect(calls.allSatisfy { !($0.arguments.contains("GIT_OPTIONAL_LOCKS=0")) })
    }

    @Test
    func removeWorktreeRunsMutatingGitWithoutLockEnv() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        try await store.removeWorktree(repositoryRoot: "/repo", path: "/repo-feature")

        let calls = await runner.calls
        #expect(calls.contains { call in
            call.executable == "git"
                && call.arguments == ["worktree", "remove", "/repo-feature"]
        }, "worktree remove must run mutating git directly; got \(calls)")
    }

    // MARK: Output / error mapping

    @Test
    func createWorktreeMapsNonZeroExitToLastError() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: "",
            stderr: "fatal: a branch named 'feature' already exists",
            exitStatus: 128,
            timedOut: false,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        await #expect(throws: GitWorktreeError.self) {
            _ = try await store.createWorktree(
                repositoryRoot: "/repo",
                branchName: "feature",
                destinationPath: "/repo-feature"
            )
        }
        #expect(store.lastErrorMessage?.contains("already exists") == true)
    }

    @Test
    func createWorktreeMapsLaunchFailureToLastError() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            executionError: "could not spawn git"
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        await #expect(throws: GitWorktreeError.self) {
            _ = try await store.createWorktree(
                repositoryRoot: "/repo",
                branchName: "feature",
                destinationPath: "/repo-feature"
            )
        }
        #expect(store.lastErrorMessage?.contains("Could not create worktree") == true)
    }

    @Test
    func createWorktreeMapsTimeoutToFailure() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner, gitTimeout: 5)

        await #expect(throws: GitWorktreeError.self) {
            _ = try await store.createWorktree(
                repositoryRoot: "/repo",
                branchName: "feature",
                destinationPath: "/repo-feature"
            )
        }
        #expect(store.lastErrorMessage?.contains("Could not create worktree") == true)
    }

    // MARK: Cancel mapping

    @Test
    func cancelledCreateShortCircuitsWithoutSpawning() async throws {
        let runner = RecordingWorktreeRunner(result: CommandResult(
            stdout: "should-not-be-used",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let store = GitWorktreeStore(defaults: Self.makeDefaults(), commandRunner: runner)

        let task = Task { @MainActor in
            try await store.createWorktree(
                repositoryRoot: "/repo",
                branchName: "feature",
                destinationPath: "/repo-feature"
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("createWorktree should throw when cancelled before spawning git")
        } catch {
            // expected: commandFailed
        }

        let calls = await runner.calls
        #expect(calls.isEmpty, "cancelled task must not spawn git; got \(calls)")
    }

    // MARK: Helpers

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cmux-git-worktree-store-tests-\(UUID().uuidString)")!
    }
}

/// A `CommandRunning` fake that records every invocation and returns a fixed
/// `CommandResult`, so the store's executable/argument/timeout shape and
/// result-mapping can be asserted without spawning a real process.
private actor RecordingWorktreeRunner: CommandRunning {
    struct Call: Sendable, Equatable {
        let directory: String
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private(set) var calls: [Call] = []
    private let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        calls.append(Call(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        return result
    }
}
