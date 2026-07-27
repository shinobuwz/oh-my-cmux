import CmuxFoundation
import Foundation
import Testing

@testable import CmuxGit

@Suite struct SystemGitWorktreeCommandRunnerTests {
    // MARK: Read-only GIT_OPTIONAL_LOCKS=0 vs mutating env

    @Test func nonLockingRunInvokesGitThroughGitOptionalLocksEnv() async throws {
        let runner = RecordingCommandRunner(result: .success)
        let worktreeRunner = SystemGitWorktreeCommandRunner(commandRunner: runner)

        _ = await worktreeRunner.runGit(
            arguments: ["worktree", "list", "--porcelain"],
            directory: "/tmp",
            nonLocking: true
        )

        let call = try #require(await runner.calls.first)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments == ["GIT_OPTIONAL_LOCKS=0", "git", "worktree", "list", "--porcelain"])
        #expect(call.directory == "/tmp")
    }

    @Test func mutatingRunInvokesGitDirectlyWithoutLockEnv() async throws {
        let runner = RecordingCommandRunner(result: .success)
        let worktreeRunner = SystemGitWorktreeCommandRunner(commandRunner: runner)

        _ = await worktreeRunner.runGit(
            arguments: ["worktree", "add", "-b", "feature", "/tmp/wt", "HEAD"],
            directory: "/tmp",
            nonLocking: false
        )

        let call = try #require(await runner.calls.first)
        #expect(call.executable == "git")
        #expect(call.arguments == ["worktree", "add", "-b", "feature", "/tmp/wt", "HEAD"])
        #expect(!call.arguments.contains("GIT_OPTIONAL_LOCKS=0"))
    }

    // MARK: Finite deadline (the cancellation safety net)

    @Test func injectedTimeoutIsForwardedToRunner() async throws {
        let runner = RecordingCommandRunner(result: .success)
        let worktreeRunner = SystemGitWorktreeCommandRunner(commandRunner: runner, timeout: 12)

        _ = await worktreeRunner.runGit(
            arguments: ["rev-parse", "--show-toplevel"],
            directory: "/tmp",
            nonLocking: true
        )

        let call = try #require(await runner.calls.first)
        #expect(call.timeout == 12)
    }

    @Test func defaultRunnerPassesFiniteDeadline() async throws {
        let runner = RecordingCommandRunner(result: .success)
        let worktreeRunner = SystemGitWorktreeCommandRunner(commandRunner: runner)

        _ = await worktreeRunner.runGit(
            arguments: ["status"],
            directory: "/tmp",
            nonLocking: true
        )

        let call = try #require(await runner.calls.first)
        #expect(call.timeout == SystemGitWorktreeCommandRunner.defaultTimeout)
        #expect(call.timeout != nil)
    }

    // MARK: Output mapping

    @Test func mapsSuccessfulOutputToOutcome() async {
        let runner = RecordingCommandRunner(result: CommandResult(
            stdout: "worktree /repo\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))

        let outcome = await SystemGitWorktreeCommandRunner(commandRunner: runner).runGit(
            arguments: ["worktree", "list", "--porcelain"],
            directory: "/repo",
            nonLocking: true
        )

        #expect(outcome.didSucceed)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "worktree /repo\n")
        #expect(outcome.stderr == "")
        #expect(outcome.launchError == nil)
    }

    @Test func mapsNonZeroExitPreservingStreams() async {
        let runner = RecordingCommandRunner(result: CommandResult(
            stdout: "partial",
            stderr: "fatal: not a git repository",
            exitStatus: 128,
            timedOut: false,
            executionError: nil
        ))

        let outcome = await SystemGitWorktreeCommandRunner(commandRunner: runner).runGit(
            arguments: ["worktree", "list"],
            directory: "/nope",
            nonLocking: true
        )

        #expect(!outcome.didSucceed)
        #expect(outcome.exitStatus == 128)
        #expect(outcome.stdout == "partial")
        #expect(outcome.stderr == "fatal: not a git repository")
        #expect(outcome.launchError == nil)
    }

    // MARK: Error mapping

    @Test func mapsLaunchFailureToLaunchError() async {
        let runner = RecordingCommandRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            executionError: "could not spawn git"
        ))

        let outcome = await SystemGitWorktreeCommandRunner(commandRunner: runner).runGit(
            arguments: ["status"],
            directory: "/tmp",
            nonLocking: false
        )

        #expect(!outcome.didSucceed)
        #expect(outcome.exitStatus == nil)
        #expect(outcome.launchError == "could not spawn git")
        #expect(outcome.stderr == "could not spawn git")
        #expect(outcome.stdout == "")
    }

    @Test func mapsTimeoutToFailedOutcome() async {
        let runner = RecordingCommandRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))

        let outcome = await SystemGitWorktreeCommandRunner(commandRunner: runner, timeout: 5).runGit(
            arguments: ["status"],
            directory: "/tmp",
            nonLocking: true
        )

        #expect(!outcome.didSucceed)
        #expect(outcome.exitStatus == nil)
        #expect(outcome.launchError?.contains("timed out") == true)
        #expect(outcome.stderr.contains("timed out"))
    }

    // MARK: Cancel mapping

    @Test func cancelledTaskShortCircuitsWithoutRunningGit() async throws {
        // Cancelling the task before the body runs (Task bodies never execute
        // inline) must keep `git` from spawning and report a non-success
        // outcome rather than a stale success.
        let runner = RecordingCommandRunner(result: CommandResult(
            stdout: "should-not-be-used",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let worktreeRunner = SystemGitWorktreeCommandRunner(commandRunner: runner)

        let task = Task {
            await worktreeRunner.runGit(
                arguments: ["status", "--porcelain=v1", "-z"],
                directory: "/tmp",
                nonLocking: true
            )
        }
        task.cancel()
        let outcome = await task.value

        let calls = await runner.calls
        #expect(calls.isEmpty, "cancelled task must not spawn git; got \(calls)")
        #expect(!outcome.didSucceed)
        #expect(outcome.launchError == "cancelled")
    }

    // MARK: End-to-end env proof against real git

    @Test func nonLockingStatusDoesNotRefreshGitIndex() async throws {
        // Proves the `/usr/bin/env GIT_OPTIONAL_LOCKS=0 git` path actually sets
        // the variable for the real `git` process: a non-locking `git status`
        // must not touch `.git/index`.
        let repo = try Self.makeTemporaryRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let tracked = repo.appendingPathComponent("tracked.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "tracked.txt"], in: repo)
        try Self.runGit(["commit", "-m", "initial"], in: repo)

        let indexURL = repo.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        // A newer mtime forces git to consider the file for a refresh; under
        // GIT_OPTIONAL_LOCKS=0 it must still leave the index byte-identical.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: tracked.path
        )

        let outcome = await SystemGitWorktreeCommandRunner().runGit(
            arguments: ["status", "--porcelain=v1", "-z"],
            directory: repo.path,
            nonLocking: true
        )

        #expect(outcome.didSucceed)
        let indexAfter = try Data(contentsOf: indexURL)
        #expect(indexAfter == indexBefore)
    }

    // MARK: Helpers

    private static func makeTemporaryRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"], in: root)
        try runGit(["config", "user.name", "cmux tests"], in: root)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: root)
        return root
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}

private extension CommandResult {
    static let success = CommandResult(
        stdout: "",
        stderr: "",
        exitStatus: 0,
        timedOut: false,
        executionError: nil
    )
}

/// Records every `run` invocation and returns a fixed `CommandResult`, so the
/// runner's argument/env/timeout shape and result-mapping can be asserted
/// without spawning a real process.
private actor RecordingCommandRunner: CommandRunning {
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
