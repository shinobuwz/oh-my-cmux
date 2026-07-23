import Foundation

/// Typed errors thrown by ``GitWorktreeService`` worktree operations.
///
/// The service never surfaces a raw `git` failure or filesystem failure as an
/// unstructured error: every failure path is mapped to one of these cases so a
/// coordinator can branch on cause and show the exact git diagnostic. Command
/// failures carry git's verbatim standard error and exit status so the user sees
/// the same message they would on the command line.
public enum GitWorktreeError: Error, Equatable, Sendable {
    /// A branch name failed validation — it was empty or contained characters or
    /// shapes git rejects as a branch ref. The associated value is the offending
    /// name as supplied.
    case invalidBranchName(String)

    /// A filesystem operation the service performs directly (creating the
    /// managed layout, appending to `.git/info/exclude`) failed. `operation` is
    /// a short label for what was attempted; `error` is the underlying error
    /// description.
    case filesystemFailure(operation: String, error: String)

    /// A `git` command exited non-zero or could not be launched.
    ///
    /// - `command`: a short label for the command (e.g. `git worktree add`).
    /// - `exitStatus`: the process exit status, or `nil` when git could not be
    ///   spawned at all.
    /// - `stderr`: git's verbatim standard error (or the launch-failure
    ///   description when the process never started), so callers can show the
    ///   exact diagnostic.
    case commandFailed(command: String, exitStatus: Int32?, stderr: String)
}

extension GitWorktreeError {
    /// A short, stable label for the error case, suitable for logging.
    public var caseLabel: String {
        switch self {
        case .invalidBranchName: "invalidBranchName"
        case .filesystemFailure: "filesystemFailure"
        case .commandFailed: "commandFailed"
        }
    }
}
