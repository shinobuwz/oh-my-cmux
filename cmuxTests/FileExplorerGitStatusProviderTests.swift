import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct FileExplorerGitStatusProviderTests {
    @Test
    func statusQueryDoesNotRefreshGitIndex() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try Self.initializeRepo(at: repoURL)

        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "tracked.txt"], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)

        let indexURL = repoURL.appendingPathComponent(".git/index")
        let indexBeforeStatus = try Data(contentsOf: indexURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: trackedURL.path
        )

        _ = await GitStatusProvider().fetchStatus(directory: repoURL.path)

        let indexAfterStatus = try Data(contentsOf: indexURL)
        #expect(indexAfterStatus == indexBeforeStatus)
    }

    @Test
    func statusQueryPreservesQuotedAndEscapedFilenames() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let nestedURL = repoURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let trackedURL = nestedURL.appendingPathComponent("quoted \"name\" and \\ slash.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let status = await GitStatusProvider().fetchStatus(directory: nestedURL.path)

        #expect(status[trackedURL.path] == .some(.modified))
    }

    @Test
    func statusQueryExcludesSiblingPathPrefixes() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let explorerRootURL = repoURL.appendingPathComponent("work", isDirectory: true)
        let siblingURL = repoURL.appendingPathComponent("workspace-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: explorerRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)

        let visibleURL = explorerRootURL.appendingPathComponent("tracked.txt")
        let siblingFileURL = siblingURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "one\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two changed\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "two changed\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        let status = await GitStatusProvider().fetchStatus(directory: explorerRootURL.path)

        #expect(status[visibleURL.path] == .some(.modified))
        #expect(status[siblingFileURL.path] == nil)
        #expect(status[siblingURL.path] == nil)
    }

    @Test
    func statusQueryRunsNonLockingGitAndParsesTypeChangedAndUnmergedEntries() async throws {
        // Asserts the read-only path invokes `/usr/bin/env GIT_OPTIONAL_LOCKS=0 git …`
        // (non-locking) for both rev-parse and status, and parses type-change and
        // unmerged entries to `.modified`.
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let runner = RecordingStatusCommandRunner(results: [
            CommandResult(
                stdout: repoURL.path,
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
            CommandResult(
                stdout: " T type-change.txt\0UU conflicted.txt\0",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
        ])
        let provider = GitStatusProvider(commandRunner: runner)

        let status = await provider.fetchStatus(directory: repoURL.path)

        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls[0].executable == "/usr/bin/env")
        #expect(calls[0].arguments == ["GIT_OPTIONAL_LOCKS=0", "git", "rev-parse", "--show-toplevel"])
        #expect(calls[1].executable == "/usr/bin/env")
        #expect(calls[1].arguments == ["GIT_OPTIONAL_LOCKS=0", "git", "status", "--porcelain=v1", "-z"])
        #expect(calls.allSatisfy { $0.timeout != nil })
        #expect(
            status[repoURL.appendingPathComponent("type-change.txt").path] == .some(.modified)
        )
        #expect(
            status[repoURL.appendingPathComponent("conflicted.txt").path] == .some(.modified)
        )
    }

    @Test
    func sshStatusQueryDispatchesThroughInjectedCommandRunner() async throws {
        // The ssh status path runs `ssh` via the injected CommandRunning seam
        // with a finite deadline and parses the framed output.
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let runner = RecordingStatusCommandRunner(results: [
            CommandResult(
                stdout: "\(repoURL.path)\n---GIT_STATUS---\n M remote.txt\0",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
        ])
        let provider = GitStatusProvider(commandRunner: runner)

        let status = await provider.fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].executable == "ssh")
        #expect(calls[0].timeout != nil)
        #expect(calls[0].arguments.contains("example.invalid"))
        #expect(
            status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified)
        )
    }

    @Test
    func sshStatusQueryOverridesHostConfiguredRemoteCommand() async throws {
        // The remote git status runs as an ssh command-line command, which
        // OpenSSH refuses while a host-configured RemoteCommand is in effect
        // (issue #7246) — the argv must carry `-o RemoteCommand=none` before
        // the destination.
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let runner = RecordingStatusCommandRunner(results: [
            CommandResult(
                stdout: "\(repoURL.path)\n---GIT_STATUS---\n M remote.txt\0",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
        ])
        let provider = GitStatusProvider(commandRunner: runner)

        _ = await provider.fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        let calls = await runner.calls
        let argv = try #require(calls.first?.arguments)
        let overrideIndex = argv.indices.dropLast().first {
            argv[$0] == "-o" && argv[$0 + 1] == "RemoteCommand=none"
        }
        let destinationIndex = argv.firstIndex(of: "example.invalid")
        #expect(overrideIndex != nil, "\(argv)")
        #expect(destinationIndex != nil, "\(argv)")
        if let overrideIndex, let destinationIndex {
            #expect(overrideIndex < destinationIndex)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-explorer-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL.resolvingSymlinksInPath()
    }

    private static func initializeRepo(at repoURL: URL) throws {
        try Self.runGit(["init"], in: repoURL)
        try Self.runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try Self.runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
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

/// A `CommandRunning` fake that returns canned `CommandResult`s in call order
/// and records every invocation, so the provider's executable/argument/timeout
/// shape can be asserted without spawning a real process.
private actor RecordingStatusCommandRunner: CommandRunning {
    struct Call: Sendable, Equatable {
        let directory: String
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private let results: [CommandResult]
    private var nextIndex = 0
    private(set) var calls: [Call] = []

    init(results: [CommandResult]) {
        self.results = results
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
        let result = nextIndex < results.count
            ? results[nextIndex]
            : CommandResult(stdout: "", stderr: "", exitStatus: 0, timedOut: false, executionError: nil)
        nextIndex += 1
        return result
    }
}
