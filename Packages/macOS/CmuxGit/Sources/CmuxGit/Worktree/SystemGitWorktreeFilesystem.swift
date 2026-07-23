import Foundation

/// The production ``GitWorktreeFilesystem``, backed by `FileManager`.
///
/// Stateless: `FileManager.default` is used as a local inside each method rather
/// than stored, so the struct is trivially `Sendable` and never carries
/// non-`Sendable` state across a concurrency boundary.
public struct SystemGitWorktreeFilesystem: GitWorktreeFilesystem, Sendable {
    /// Creates a system filesystem.
    public init() {}

    public func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func createDirectory(at path: String, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    public func readUTF8(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    public func writeUTF8(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
