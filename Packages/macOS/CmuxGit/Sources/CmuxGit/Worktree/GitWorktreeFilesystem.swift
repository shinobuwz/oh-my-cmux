import Foundation

/// The injection seam for the small set of filesystem operations
/// ``GitWorktreeService`` performs directly: creating the managed worktree
/// layout and idempotently updating `.git/info/exclude`.
///
/// Production code uses ``SystemGitWorktreeFilesystem``; tests inject a fake
/// conforming type (for example an in-memory store) so layout and exclude writes
/// can be asserted without touching the real filesystem. Inject an
/// `any GitWorktreeFilesystem` at the call site via
/// ``GitWorktreeService/init(commands:filesystem:)``.
public protocol GitWorktreeFilesystem: Sendable {
    /// Whether a directory exists at `path`.
    func directoryExists(at path: String) -> Bool

    /// Creates a directory at `path`, creating intermediate directories when
    /// `withIntermediateDirectories` is `true`.
    ///
    /// - Parameters:
    ///   - path: The directory to create.
    ///   - withIntermediateDirectories: Whether to create intermediate parents.
    /// - Throws: A filesystem error when the directory cannot be created.
    func createDirectory(at path: String, withIntermediateDirectories: Bool) throws

    /// Reads the UTF-8 contents of the file at `path`, or `nil` when it is
    /// missing or unreadable.
    func readUTF8(at path: String) -> String?

    /// Writes `content` to `path` atomically as UTF-8, overwriting any existing
    /// contents.
    ///
    /// - Parameters:
    ///   - content: The text to write.
    ///   - path: The file to write.
    /// - Throws: A filesystem error when the file cannot be written.
    func writeUTF8(_ content: String, to path: String) throws
}
