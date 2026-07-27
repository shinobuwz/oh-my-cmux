import CmuxFoundation
import Foundation

/// The production ``GitWorktreeCommandRunning``: runs `git` via the injected
/// ``CommandRunning`` seam (``CmuxFoundation/CommandRunner`` by default) and
/// translates its ``CommandResult`` into a ``GitWorktreeCommandOutcome``.
///
/// Process spawning, concurrent stdout/stderr draining, and deadline
/// enforcement all live in ``CmuxFoundation/CommandRunner``; this type is the
/// thin adapter that maps the CmuxFoundation result shape onto the worktree
/// service's outcome and layers in the per-call `GIT_OPTIONAL_LOCKS=0`
/// environment for read-only commands.
///
/// `nonLocking` is implemented by invoking `/usr/bin/env
/// GIT_OPTIONAL_LOCKS=0 git …` so the variable reaches the child regardless of
/// how the injected runner treats its own environment dictionary. Mutating
/// commands run `git …` directly with the runner's resolved environment.
public struct SystemGitWorktreeCommandRunner: GitWorktreeCommandRunning, Sendable {
    /// The deadline (seconds) applied to every `git` invocation. A finite
    /// deadline is the cancellation safety net: a caller that drops or cancels
    /// its task is guaranteed the `git` process is terminated rather than
    /// orphaned indefinitely.
    nonisolated static let defaultTimeout: Double = 30

    private let commandRunner: any CommandRunning
    private let timeout: Double

    /// Creates a command runner backed by ``CmuxFoundation/CommandRunner`` with
    /// the default finite deadline.
    public init() {
        self.init(commandRunner: CommandRunner(), timeout: SystemGitWorktreeCommandRunner.defaultTimeout)
    }

    /// Creates a command runner with an injected ``CommandRunning`` seam and
    /// deadline. Internal so the package's public surface does not expose
    /// CmuxFoundation types; tests reach it through `@testable import CmuxGit`.
    ///
    /// - Parameters:
    ///   - commandRunner: The ``CommandRunning`` seam that spawns `git`. Inject
    ///     a fake in tests so they never spawn a real process.
    ///   - timeout: The finite deadline (seconds) for each `git` invocation.
    init(
        commandRunner: any CommandRunning,
        timeout: Double = SystemGitWorktreeCommandRunner.defaultTimeout
    ) {
        self.commandRunner = commandRunner
        self.timeout = timeout
    }

    public func runGit(
        arguments: [String],
        directory: String,
        nonLocking: Bool
    ) async -> GitWorktreeCommandOutcome {
        // A caller that has already cancelled its task should not start a fresh
        // `git` process. mid-run cancellation is bounded by `timeout`.
        if Task.isCancelled {
            return GitWorktreeCommandOutcome(
                exitStatus: nil, stdout: "", stderr: "", launchError: "cancelled"
            )
        }
        let invocation = Self.invocation(arguments: arguments, nonLocking: nonLocking)
        let result = await commandRunner.run(
            directory: directory,
            executable: invocation.executable,
            arguments: invocation.arguments,
            timeout: timeout
        )
        return Self.map(result, timeout: timeout)
    }

    /// Resolves the runner invocation for `git <arguments>`, layering in
    /// `GIT_OPTIONAL_LOCKS=0` for non-locking (read-only) commands.
    nonisolated private static func invocation(
        arguments: [String], nonLocking: Bool
    ) -> (executable: String, arguments: [String]) {
        if nonLocking {
            return ("/usr/bin/env", ["GIT_OPTIONAL_LOCKS=0", "git"] + arguments)
        }
        return ("git", arguments)
    }

    /// Translates a ``CommandResult`` into a ``GitWorktreeCommandOutcome``,
    /// preserving stdout/stderr/exitStatus on a normal exit, surfacing the
    /// spawn error on a launch failure, and reporting a timeout as a failed
    /// outcome whose `launchError` and `stderr` describe the deadline.
    nonisolated private static func map(
        _ result: CommandResult, timeout: Double
    ) -> GitWorktreeCommandOutcome {
        if result.timedOut {
            let message = "git command timed out after \(timeout) seconds"
            return GitWorktreeCommandOutcome(
                exitStatus: nil,
                stdout: result.stdout ?? "",
                stderr: message,
                launchError: message
            )
        }
        return GitWorktreeCommandOutcome(
            exitStatus: result.exitStatus,
            stdout: result.stdout ?? "",
            stderr: result.stderr ?? result.executionError ?? "",
            launchError: result.executionError
        )
    }
}
