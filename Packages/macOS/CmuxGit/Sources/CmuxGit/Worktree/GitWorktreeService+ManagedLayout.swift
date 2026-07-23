import Foundation

extension GitWorktreeService {
    /// Ensures the managed-worktree layout exists and the managed directory is
    /// ignored, preparing a repository before a worktree is created there.
    ///
    /// Creates `<mainRoot>/.cmux-worktrees/` and the shared
    /// `<commonDirectory>/info/` directory if absent, then idempotently appends
    /// ``managedWorktreesExcludePattern`` (`.cmux-worktrees/`) to the main
    /// repository's `.git/info/exclude` so the managed directory — and every
    /// worktree beneath it — stays untracked. The exclude append is a
    /// read-modify-write that skips work when the pattern line is already
    /// present, so it is safe to call before every creation.
    ///
    /// - Parameter repository: The resolved repository to prepare.
    /// - Throws: ``GitWorktreeError/filesystemFailure(operation:error:)`` when a
    ///   directory cannot be created or the exclude file cannot be updated.
    func ensureManagedLayout(
        in repository: ResolvedWorktreeRepository
    ) throws {
        let managedDirectory = URL(fileURLWithPath: repository.mainRoot, isDirectory: true)
            .appendingPathComponent(Self.managedWorktreesDirectoryName, isDirectory: true)
            .standardizedFileURL
            .path
        let infoDirectory = URL(fileURLWithPath: repository.commonDirectory, isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
            .standardizedFileURL
            .path
        let excludeFile = URL(fileURLWithPath: infoDirectory, isDirectory: true)
            .appendingPathComponent("exclude")
            .standardizedFileURL
            .path

        if !filesystem.directoryExists(at: managedDirectory) {
            do {
                try filesystem.createDirectory(
                    at: managedDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw GitWorktreeError.filesystemFailure(
                    operation: "create managed worktree directory",
                    error: String(describing: error)
                )
            }
        }
        if !filesystem.directoryExists(at: infoDirectory) {
            do {
                try filesystem.createDirectory(
                    at: infoDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw GitWorktreeError.filesystemFailure(
                    operation: "create git info directory",
                    error: String(describing: error)
                )
            }
        }

        try appendManagedExcludeLine(to: excludeFile)
    }

    /// Idempotently appends the managed-directory ignore pattern to `excludeFile`.
    private nonisolated func appendManagedExcludeLine(to excludeFile: String) throws {
        let existing = filesystem.readUTF8(at: excludeFile) ?? ""
        let pattern = Self.managedWorktreesExcludePattern
        let alreadyPresent = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                line.trimmingCharacters(in: .whitespaces) == pattern
            }
        guard !alreadyPresent else { return }

        let prefix = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        let updated = existing + prefix + pattern + "\n"
        do {
            try filesystem.writeUTF8(updated, to: excludeFile)
        } catch {
            throw GitWorktreeError.filesystemFailure(
                operation: "update git info/exclude",
                error: String(describing: error)
            )
        }
    }
}
