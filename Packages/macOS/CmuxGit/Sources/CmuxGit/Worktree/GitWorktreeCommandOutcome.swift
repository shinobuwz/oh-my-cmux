import Foundation

/// The captured outcome of one `git` invocation, returned by
/// ``GitWorktreeCommandRunning``.
///
/// A value alternative to Foundation's process result: it pairs the decoded
/// standard streams with the exit status and a launch-failure field, so the
/// service can translate a non-zero or unlaunched command into a typed
/// ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)`` that carries
/// the exact diagnostic.
public struct GitWorktreeCommandOutcome: Sendable, Equatable {
    /// The process exit status, or `nil` when git could not be spawned.
    public let exitStatus: Int32?

    /// Decoded standard output (empty string when none was produced).
    public let stdout: String

    /// Decoded standard error (empty string when none was produced; for a launch
    /// failure this carries the spawn-error description).
    public let stderr: String

    /// A description of the spawn failure when git could not be launched, else
    /// `nil`.
    public let launchError: String?

    /// `true` when git launched and exited with status `0`.
    public var didSucceed: Bool {
        launchError == nil && exitStatus == 0
    }

    /// Creates a command outcome.
    ///
    /// - Parameters:
    ///   - exitStatus: The process exit status, or `nil` when the process never
    ///     launched.
    ///   - stdout: UTF-8 standard output (use an empty string when unavailable).
    ///   - stderr: UTF-8 standard error (use an empty string when unavailable).
    ///   - launchError: A spawn-failure description, or `nil` when git launched.
    public init(exitStatus: Int32?, stdout: String, stderr: String, launchError: String?) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.launchError = launchError
    }
}
