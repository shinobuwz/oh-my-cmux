import Foundation
import Darwin

/// The production ``GitWorktreeCommandRunning``: runs `git` via `/usr/bin/env`
/// off the calling thread and captures its output.
///
/// Standard output and standard error are drained on concurrent detached utility
/// tasks that are started *after* the process successfully launches and *before*
/// ``Process/waitUntilExit()`` is called. This ordering is the only one that
/// avoids both deadlock shapes: starting readers before `run()` succeeds would
/// block forever on a pipe whose write end never connects when `run()` throws,
/// while waiting for exit before reading would block once output exceeds the pipe
/// buffer. The parent's pipe write ends are closed so the readers reach EOF once
/// the child closes its copies.
///
/// The drain tasks are keyed by the raw file descriptor (an `Int32` is
/// `Sendable`), so no non-`Sendable` `FileHandle` crosses a task boundary and no
/// lock or `@unchecked Sendable` holder is required.
public struct SystemGitWorktreeCommandRunner: GitWorktreeCommandRunning, Sendable {
    /// The environment `git` runs with. Stored as an immutable dictionary so the
    /// struct stays `Sendable`; `GIT_OPTIONAL_LOCKS=0` is layered in per call.
    private let environment: [String: String]

    /// Creates a command runner.
    ///
    /// - Parameter environment: The environment `git` runs with; defaults to the
    ///   process environment. `GIT_OPTIONAL_LOCKS` is set per call from
    ///   `nonLocking`, overriding any value present here.
    public init() {
        self.environment = ProcessInfo.processInfo.environment
    }

    /// Creates a command runner with an explicit environment.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func runGit(
        arguments: [String],
        directory: String,
        nonLocking: Bool
    ) async -> GitWorktreeCommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var env = environment
        if nonLocking { env["GIT_OPTIONAL_LOCKS"] = "0" }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return GitWorktreeCommandOutcome(
                exitStatus: nil,
                stdout: "",
                stderr: error.localizedDescription,
                launchError: error.localizedDescription
            )
        }

        // Drain both streams concurrently on detached tasks started before
        // waitUntilExit so a full pipe buffer cannot deadlock the child. Keyed by
        // the raw file descriptor (Int32 is Sendable) so the drain tasks stay
        // Sendable-clean under Swift 6 concurrency.
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        let stdoutTask = Task.detached(priority: .utility) { Self.readToEnd(fileDescriptor: outFD) }
        let stderrTask = Task.detached(priority: .utility) { Self.readToEnd(fileDescriptor: errFD) }

        // Drop the parent's write ends so the readers reach EOF once the child
        // (and any descendants that inherited them) close their copies.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        return GitWorktreeCommandOutcome(
            exitStatus: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            launchError: nil
        )
    }

    /// Reads a file descriptor to EOF using `read(2)`, tolerating `EINTR`.
    ///
    /// A static method (not a free function) per the package's no-top-level-func
    /// rule; it owns no state and is safe to call from a detached drain task.
    nonisolated static func readToEnd(fileDescriptor: Int32) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}
