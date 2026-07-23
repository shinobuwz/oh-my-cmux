import Foundation

/// The injection seam for spawning `git` and capturing its output.
///
/// Production code uses ``SystemGitWorktreeCommandRunner``; tests inject a fake
/// conforming type so they never spawn a real process. Inject an
/// `any GitWorktreeCommandRunning` at the call site (via
/// ``GitWorktreeService/init(commands:filesystem:)``) rather than reaching for a
/// global runner.
///
/// The concrete runner drains standard output and standard error concurrently
/// before waiting for the process to exit, so a command whose output exceeds the
/// pipe buffer can never deadlock.
public protocol GitWorktreeCommandRunning: Sendable {
    /// Runs `git <arguments>` with its working directory set to `directory` and
    /// captures standard output and standard error.
    ///
    /// `nonLocking` sets `GIT_OPTIONAL_LOCKS=0` for read-only commands so a
    /// concurrent `git` in another surface cannot block the worktree listing.
    /// Mutating commands (`worktree add`/`remove`/`prune`) must run with the full
    /// environment and therefore pass `nonLocking: false`.
    ///
    /// - Parameters:
    ///   - arguments: The arguments passed to `git` (without the `git` token).
    ///   - directory: The working directory for the process.
    ///   - nonLocking: When `true`, runs with `GIT_OPTIONAL_LOCKS=0`.
    /// - Returns: The captured ``GitWorktreeCommandOutcome``.
    func runGit(
        arguments: [String],
        directory: String,
        nonLocking: Bool
    ) async -> GitWorktreeCommandOutcome
}

extension GitWorktreeCommandRunning {
    /// Runs a non-locking `git` read command and returns its standard output only
    /// when it launched and exited with status `0`; otherwise `nil`.
    ///
    /// - Parameters:
    ///   - arguments: The arguments passed to `git` (without the `git` token).
    ///   - directory: The working directory for the process.
    /// - Returns: The captured standard output on success, or `nil`.
    public func runStandardOutput(
        arguments: [String],
        directory: String
    ) async -> String? {
        let outcome = await runGit(arguments: arguments, directory: directory, nonLocking: true)
        guard outcome.didSucceed else { return nil }
        return outcome.stdout
    }
}
