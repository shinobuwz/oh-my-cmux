import CmuxFoundation
import Darwin
import Foundation

/// Runs non-locking `git status --porcelain` and parses results into a
/// path-to-status map.
///
/// All `git` invocations go through an injected ``CommandRunning`` seam
/// (``CmuxFoundation/CommandRunner`` by default) with a finite deadline, so a
/// dropped/cancelled caller never leaves `git` running indefinitely. Read-only
/// commands run as `/usr/bin/env GIT_OPTIONAL_LOCKS=0 git …` so a concurrent
/// `git` in another surface cannot block on the index lock. The methods are
/// `async` and cooperate with task cancellation: a cancelled task short-circuits
/// before each subprocess invocation rather than spawning `git` regardless.
struct GitStatusProvider: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    private static let nonLockingRemoteGitCommand = "env \(nonLockingGitEnvironmentKey)=\(nonLockingGitEnvironmentValue) git"

    private let commandRunner: any CommandRunning
    private let timeout: TimeInterval

    /// Creates a status provider.
    ///
    /// - Parameters:
    ///   - commandRunner: The ``CommandRunning`` seam that spawns `git`/`ssh`.
    ///     Defaults to ``CmuxFoundation/CommandRunner``. Inject a fake in tests.
    ///   - timeout: The finite deadline (seconds) for each invocation.
    init(
        commandRunner: any CommandRunning = CommandRunner(),
        timeout: TimeInterval = 30
    ) {
        self.commandRunner = commandRunner
        self.timeout = timeout
    }

    func fetchStatus(directory: String) async -> [String: GitFileStatus] {
        if Task.isCancelled { return [:] }
        guard let repoRoot = await gitRepoRoot(for: directory) else { return [:] }
        if Task.isCancelled { return [:] }
        let output = await runGit(in: repoRoot, arguments: ["status", "--porcelain=v1", "-z"])
        return parseGitStatus(
            output: output,
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) async -> [String: GitFileStatus] {
        if Task.isCancelled { return [:] }
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = [
            "cd '\(escapedDir)' 2>/dev/null",
            "\(Self.nonLockingRemoteGitCommand) rev-parse --show-toplevel 2>/dev/null",
            "echo '---GIT_STATUS---'",
            "\(Self.nonLockingRemoteGitCommand) status --porcelain=v1 -z 2>/dev/null",
        ].joined(separator: " && ")
        guard let output = await runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
    }

    private func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String
    ) -> [String: GitFileStatus] {
        guard let output, !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]
        let normalizedRepoRoot = Self.pathWithoutTrailingSlashes(repoRoot)
        let normalizedExplorerRoot = Self.pathWithoutTrailingSlashes(explorerRoot)
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        var entryIndex = 0
        while entryIndex < entries.count {
            let entry = entries[entryIndex]
            guard entry.count >= 4 else {
                entryIndex += 1
                continue
            }
            let indexStatus = entry[entry.startIndex]
            let workTreeStatus = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            let usesSecondPath = Self.statusUsesSecondPath(index: indexStatus, workTree: workTreeStatus)
            entryIndex += usesSecondPath ? 2 : 1
            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = Self.absolutePath(repoRoot: normalizedRepoRoot, relativePath: path)
            guard Self.path(absolutePath, isContainedIn: normalizedExplorerRoot) else { continue }

            statusMap[absolutePath] = status
            markParentDirectories(
                absolutePath: absolutePath,
                explorerRoot: normalizedExplorerRoot,
                status: status,
                in: &statusMap
            )
        }
        return statusMap
    }

    private func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "U" || workTree == "U" { return .modified }
        if index == "T" || workTree == "T" { return .modified }
        if index == "A" || workTree == "A" { return .added }
        if index == "C" || workTree == "C" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private func markParentDirectories(
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while Self.path(current, isContainedIn: explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func statusUsesSecondPath(index: Character, workTree: Character) -> Bool {
        index == "R" || workTree == "R" || index == "C" || workTree == "C"
    }

    private static func absolutePath(repoRoot: String, relativePath: String) -> String {
        repoRoot == "/" ? "/" + relativePath : repoRoot + "/" + relativePath
    }

    private static func path(_ path: String, isContainedIn root: String) -> Bool {
        let normalizedPath = pathWithoutTrailingSlashes(path)
        let normalizedRoot = pathWithoutTrailingSlashes(root)
        if normalizedPath == normalizedRoot { return true }
        if normalizedRoot == "/" { return normalizedPath.hasPrefix("/") }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func pathWithoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Git canonicalizes the working directory before printing the repository
    /// root (`/var` becomes `/private/var` on macOS). Preserve the caller's path
    /// spelling so status dictionary keys still match File Explorer URLs.
    private static func repoRootPreservingDirectorySpelling(
        reportedRoot: String,
        directory: String
    ) -> String {
        let normalizedRoot = pathWithoutTrailingSlashes(reportedRoot)
        let normalizedDirectory = pathWithoutTrailingSlashes(directory)
        guard let rootPointer = Darwin.realpath(normalizedRoot, nil) else {
            return normalizedRoot
        }
        defer { free(rootPointer) }
        guard let directoryPointer = Darwin.realpath(normalizedDirectory, nil) else {
            return normalizedRoot
        }
        defer { free(directoryPointer) }

        let resolvedRoot = pathWithoutTrailingSlashes(String(cString: rootPointer))
        let resolvedDirectory = pathWithoutTrailingSlashes(String(cString: directoryPointer))
        guard path(resolvedDirectory, isContainedIn: resolvedRoot) else {
            return normalizedRoot
        }
        let relativeSuffix = String(resolvedDirectory.dropFirst(resolvedRoot.count))
        guard !relativeSuffix.isEmpty else { return normalizedDirectory }
        guard normalizedDirectory.hasSuffix(relativeSuffix) else { return normalizedRoot }
        return String(normalizedDirectory.dropLast(relativeSuffix.count))
    }

    private func gitRepoRoot(for directory: String) async -> String? {
        guard let output = await runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"]) else {
            return nil
        }
        return Self.repoRootPreservingDirectorySpelling(
            reportedRoot: output.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: directory
        )
    }

    /// Runs a non-locking `git <arguments>` in `directory` and returns its
    /// standard output only when it launched, did not time out, and exited `0`.
    private func runGit(in directory: String, arguments: [String]) async -> String? {
        if Task.isCancelled { return nil }
        let result = await commandRunner.run(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: ["GIT_OPTIONAL_LOCKS=0", "git"] + arguments,
            timeout: timeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else { return nil }
        return result.stdout
    }

    private func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) async -> String? {
        if Task.isCancelled { return nil }
        // The positional command conflicts with a host-configured
        // RemoteCommand unless overridden (issue #7246).
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [destination, command]
        let result = await commandRunner.run(
            directory: FileManager.default.temporaryDirectory.path,
            executable: "ssh",
            arguments: args,
            timeout: timeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else { return nil }
        return result.stdout
    }
}
