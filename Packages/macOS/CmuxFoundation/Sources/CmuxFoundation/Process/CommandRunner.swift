public import Foundation
import Darwin
import os

/// Sendable ownership boundary for Dispatch's thread-safe timer source.
private final class CommandTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    func schedule(deadline: DispatchTime) {
        source.schedule(deadline: deadline)
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func cancel() {
        source.cancel()
    }

    func resume() {
        source.resume()
    }
}

/// Runs external commands with `Process`, capturing output and honoring an
/// optional deadline and parent `Task` cancellation.
///
/// This is the production ``CommandRunning``. It resolves bare command names
/// against `PATH`, a bundled `bin` directory, and a set of fallback directories
/// (all injectable for tests), captures `stdout`/`stderr` with `DispatchSourceRead`
/// on a dedicated queue so no Swift cooperative worker thread is ever parked in a
/// blocking `read(2)`, and resolves the run exactly once through three competing
/// paths — normal completion (both pipes EOF + process exit), the deadline timer,
/// and parent `Task` cancellation. Whichever path wins cancels the others,
/// terminates the child per the existing SIGTERM→SIGKILL policy, and closes the
/// runner-owned pipe file descriptors.
///
/// ```swift
/// let runner = CommandRunner()
/// let token = await runner.runStandardOutput(
///     directory: ".", executable: "gh", arguments: ["auth", "token"], timeout: 5
/// )
/// ```
public struct CommandRunner: CommandRunning, Sendable {
    /// The default fallback `PATH` directories searched when a command is not on `PATH`.
    public static let defaultFallbackSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// Seconds to wait after `SIGTERM` (on timeout/cancellation) before sending `SIGKILL`.
    private static let sigkillGraceSeconds: Double = 0.2

    // Hosts the one-shot deadline/SIGKILL timers. A queue is used only for timer
    // event delivery, never to serialize mutable state.
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.timer")

    // Dedicated serial queue for non-cooperative pipe reads. `DispatchSourceRead`
    // delivers readability events here; the handler drains the fd with non-blocking
    // `read(2)` until `EAGAIN`. No Swift cooperative worker is occupied by an
    // indefinite blocking `read`, so cancellation and the deadline are never stuck
    // behind a blocked cooperative thread.
    private static let readQueue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.read")

    /// The `executionError` carried by a result resolved through parent `Task`
    /// cancellation (as opposed to a launch failure or the deadline). Used by tests.
    static let cancellationExecutionError = "cancelled"

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]

    /// Creates a command runner.
    /// - Parameters:
    ///   - environment: The environment whose `PATH` is searched; defaults to the process environment.
    ///   - bundledBinPath: An extra directory searched ahead of the fallbacks (the app's
    ///     bundled CLI directory); defaults to `Bundle.main`'s `Contents/Resources/bin`.
    ///   - fallbackSearchDirectories: Directories searched after `PATH` and the bundled bin.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories
    ) {
        self.environment = environment
        self.bundledBinPath = bundledBinPath
        self.fallbackSearchDirectories = fallbackSearchDirectories
    }

    /// Runs `executable` with `arguments` in `directory`, capturing its output.
    ///
    /// Implements ``CommandRunning/run(directory:executable:arguments:timeout:)``:
    /// resolves `executable` against the configured `PATH`/bundled-bin/fallbacks,
    /// drains `stdout`/`stderr` via dispatch read sources so large streams cannot
    /// deadlock the child, and resolves the run exactly once across normal
    /// completion, the `timeout` deadline, and parent `Task` cancellation. The
    /// winning path cancels the others, terminates (then `SIGKILL`s) the process,
    /// and closes the runner-owned pipe file descriptors. See the protocol for the
    /// full contract.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name (resolved against `PATH`) or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - timeout: A deadline in seconds; when it elapses the process is terminated
    ///     and the result has ``CommandResult/timedOut`` set. `nil` waits indefinitely
    ///     (unless the awaiting `Task` is cancelled).
    /// - Returns: The ``CommandResult`` describing how the command finished. A result
    ///   resolved through parent `Task` cancellation carries
    ///   ``cancellationExecutionError`` as its `executionError`.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let process = Process()

        // Raw pipe(2) fds so the runner owns them exclusively and deterministically
        // closes both read ends on every completion path. Foundation `Pipe` would
        // leave its `FileHandle`s closing the same fds, risking double-close / fd
        // reuse once we close them ourselves.
        var outFds: [Int32] = [0, 0]
        let outPipeOK = outFds.withUnsafeMutableBufferPointer { buffer -> Bool in
            Darwin.pipe(buffer.baseAddress!) == 0
        }
        guard outPipeOK else {
            return CommandResult(
                stdout: nil, stderr: nil, exitStatus: nil,
                timedOut: false, executionError: "pipe() failed for stdout"
            )
        }
        var errFds: [Int32] = [0, 0]
        let errPipeOK = errFds.withUnsafeMutableBufferPointer { buffer -> Bool in
            Darwin.pipe(buffer.baseAddress!) == 0
        }
        guard errPipeOK else {
            Darwin.close(outFds[0]); Darwin.close(outFds[1])
            return CommandResult(
                stdout: nil, stderr: nil, exitStatus: nil,
                timedOut: false, executionError: "pipe() failed for stderr"
            )
        }
        let outReadFD = outFds[0]
        let outWriteFD = outFds[1]
        let errReadFD = errFds[0]
        let errWriteFD = errFds[1]
        // The child adopts the write ends; the runner owns the read ends and the
        // parent copies of the write ends. closeOnDealloc:false keeps Foundation
        // from racing our explicit closes.
        process.standardOutput = FileHandle(fileDescriptor: outWriteFD, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errWriteFD, closeOnDealloc: false)

        if let resolved = resolvedCommandPath(executable: executable) {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice

        // Non-blocking read ends so the dispatch source drain loop never blocks:
        // it returns EAGAIN when drained instead of parking the queue thread.
        Self.setNonBlocking(outReadFD)
        Self.setNonBlocking(errReadFD)

        let cancelBox = CancelBox()

        return await withTaskCancellationHandler { [process] in
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                let capture = Capture(
                    continuation: continuation,
                    process: process,
                    outReadFD: outReadFD,
                    errReadFD: errReadFD
                )
                capture.installTerminationHandler()

                do {
                    try process.run()
                } catch {
                    let message = String(describing: error)
                    // Spawn failed: the child never inherited the write ends. Close
                    // the parent copies; the read ends are closed by the sources'
                    // cancel handlers during teardown.
                    Darwin.close(outWriteFD)
                    Darwin.close(errWriteFD)
                    capture.claimImmediate(
                        CommandResult(
                            stdout: nil, stderr: nil, exitStatus: nil,
                            timedOut: false, executionError: message
                        ),
                        terminateChild: false
                    )
                    return
                }

                // Close the parent's write ends so the readers see EOF once the
                // child (and any descendants that inherited them) close their copies.
                Darwin.close(outWriteFD)
                Darwin.close(errWriteFD)

                // Arm cancellation only after a successful launch, so the handler
                // can never call `cancel()`/`terminate()` on an unlaunched Process.
                // A cancel that arrived during spawn is buffered by the box and
                // fired here; a cancel that arrives afterward fires immediately.
                cancelBox.install { capture.cancel() }
                if Task.isCancelled {
                    capture.cancel()
                }
                if let timeout {
                    capture.armDeadline(timeout)
                }
            }
        } onCancel: {
            cancelBox.trigger()
        }
    }

    // MARK: - Capture

    /// Per-`run` coordination: holds the non-`Sendable` dispatch sources and the
    /// mutable capture state, all guarded by `lock`. The instance is kept alive
    /// (via `selfRetention`) until the continuation resumes; every resolving path
    /// runs `teardown` exactly once, which cancels the sources/timer, closes the
    /// read fds, optionally terminates the child, and clears the self-retention.
    ///
    /// Per CLAUDE.md's lock carve-out for synchronous coordination from non-async
    /// dispatch callbacks, an `NSLock` guards the small shared state rather than
    /// routing every callback through an actor.
    private final class Capture: @unchecked Sendable {
        let continuation: CheckedContinuation<CommandResult, Never>
        let process: Process
        let outReadFD: Int32
        let errReadFD: Int32
        private let lock = NSLock()
        private var outSource: (any DispatchSourceRead)?
        private var errSource: (any DispatchSourceRead)?
        private var stdout = Data()
        private var stderr = Data()
        private var outEOF = false
        private var errEOF = false
        private var didTerminate = false
        private var exitStatus: Int32?
        private var resumed = false
        private var tornDown = false
        private var deadlineTimer: CommandTimer?
        // Self-retention: keeps the capture alive until teardown. Without it, the
        // `[weak self]` handlers could release the instance while pipes are still
        // open (the continuation closure does not outlive its synchronous setup).
        private var selfRetention: Capture?

        init(
            continuation: CheckedContinuation<CommandResult, Never>,
            process: Process,
            outReadFD: Int32,
            errReadFD: Int32
        ) {
            self.continuation = continuation
            self.process = process
            self.outReadFD = outReadFD
            self.errReadFD = errReadFD

            let outSource = DispatchSource.makeReadSource(fileDescriptor: outReadFD, queue: CommandRunner.readQueue)
            let errSource = DispatchSource.makeReadSource(fileDescriptor: errReadFD, queue: CommandRunner.readQueue)
            // The cancel handler — not the event handler — owns closing the fd, so
            // close() never races an in-flight read(): Dispatch invokes the cancel
            // handler only after any running event handler returns.
            outSource.setCancelHandler { Darwin.close(outReadFD) }
            errSource.setCancelHandler { Darwin.close(errReadFD) }
            outSource.setEventHandler { [weak self] in self?.handleRead(source: outSource, fd: outReadFD, isOut: true) }
            errSource.setEventHandler { [weak self] in self?.handleRead(source: errSource, fd: errReadFD, isOut: false) }
            self.outSource = outSource
            self.errSource = errSource
            // Resume before launch: the read ends see no data and no EOF while the
            // parent write ends are open, so no events fire until the child writes.
            outSource.resume()
            errSource.resume()
            self.selfRetention = self
        }

        func installTerminationHandler() {
            process.terminationHandler = { [weak self] finished in
                self?.handleTermination(status: finished.terminationStatus)
            }
        }

        /// Arms the one-shot deadline. The timer is resumed while holding the lock
        /// so it can never be resumed after a concurrent `teardown` cancels it
        /// (resuming a cancelled dispatch source traps).
        func armDeadline(_ timeout: TimeInterval) {
            let timer = CommandTimer(queue: CommandRunner.timerQueue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.handleDeadline() }
            lock.lock()
            if resumed {
                lock.unlock()
                // Dispatch sources must be activated before their last release.
                // The command may finish before deadline arming reaches this
                // branch, so balance the source before cancelling the unused timer.
                timer.resume()
                timer.cancel()
            } else {
                deadlineTimer = timer
                timer.resume()
                lock.unlock()
            }
        }

        /// Resolves the run through parent `Task` cancellation: terminates the child
        /// and resumes exactly once with the cancellation result. Idempotent.
        func cancel() {
            claimImmediate(
                CommandResult(
                    stdout: nil, stderr: nil, exitStatus: nil,
                    timedOut: false, executionError: CommandRunner.cancellationExecutionError
                ),
                terminateChild: true
            )
        }

        // MARK: event handlers (run on readQueue / Foundation's termination queue / timerQueue)

        private func handleRead(source: any DispatchSourceRead, fd: Int32, isOut: Bool) {
            // Drain the fd outside the lock — this fd has a single reader, so there
            // is no contention. Only the append + completion check need the lock.
            var chunk = Data()
            var eof = false
            let chunkSize = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let (bytesRead, err) = buffer.withUnsafeMutableBytes { pointer -> (Int, Int32) in
                    guard let base = pointer.baseAddress else { return (0, 0) }
                    let n = Darwin.read(fd, base, chunkSize)
                    return (n, n >= 0 ? 0 : Darwin.errno)
                }
                if bytesRead > 0 {
                    chunk.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    eof = true
                    break
                } else if err == EINTR {
                    continue
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    break
                } else {
                    // Unrecoverable read error: treat as EOF so completion can still proceed.
                    eof = true
                    break
                }
            }
            if eof {
                source.cancel()
            }

            var result: CommandResult?
            lock.lock()
            if isOut {
                if !chunk.isEmpty { stdout.append(chunk) }
                if eof { outEOF = true }
            } else {
                if !chunk.isEmpty { stderr.append(chunk) }
                if eof { errEOF = true }
            }
            if !resumed, outEOF, errEOF, didTerminate {
                resumed = true
                result = CommandResult(
                    stdout: String(data: stdout, encoding: .utf8),
                    stderr: String(data: stderr, encoding: .utf8),
                    exitStatus: exitStatus,
                    timedOut: false,
                    executionError: nil
                )
            }
            lock.unlock()
            if let result {
                teardown(terminateChild: false)
                continuation.resume(returning: result)
            }
        }

        private func handleTermination(status: Int32) {
            var result: CommandResult?
            lock.lock()
            didTerminate = true
            exitStatus = status
            if !resumed, outEOF, errEOF, didTerminate {
                resumed = true
                result = CommandResult(
                    stdout: String(data: stdout, encoding: .utf8),
                    stderr: String(data: stderr, encoding: .utf8),
                    exitStatus: exitStatus,
                    timedOut: false,
                    executionError: nil
                )
            }
            lock.unlock()
            if let result {
                teardown(terminateChild: false)
                continuation.resume(returning: result)
            }
        }

        private func handleDeadline() {
            claimImmediate(
                CommandResult(
                    stdout: nil, stderr: nil, exitStatus: nil,
                    timedOut: true, executionError: nil
                ),
                terminateChild: true
            )
        }

        // MARK: resolution

        /// Resolves the run immediately (timeout or cancellation), independent of the
        /// pipe readers. Returns without effect if the run already resolved.
        func claimImmediate(_ result: CommandResult, terminateChild: Bool) {
            var shouldResume = false
            lock.lock()
            if !resumed {
                resumed = true
                shouldResume = true
            }
            lock.unlock()
            guard shouldResume else { return }
            teardown(terminateChild: terminateChild)
            continuation.resume(returning: result)
        }

        /// Idempotent one-shot teardown: cancels the deadline timer and both read
        /// sources (the sources' cancel handlers close the read fds), and optionally
        /// SIGTERM/SIGKILL the immediate child. Guarded by `tornDown` so the first
        /// resolving path wins and later paths are no-ops.
        private func teardown(terminateChild: Bool) {
            var outSrc: (any DispatchSourceRead)?
            var errSrc: (any DispatchSourceRead)?
            var timer: CommandTimer?
            var doTerminate = false
            var didPerform = false
            lock.lock()
            if !tornDown {
                tornDown = true
                didPerform = true
                outSrc = outSource
                errSrc = errSource
                timer = deadlineTimer
                outSource = nil
                errSource = nil
                deadlineTimer = nil
                doTerminate = terminateChild
                selfRetention = nil
            }
            lock.unlock()
            guard didPerform else { return }

            // Never deliver the deadline after the run has resolved.
            timer?.cancel()
            // Stop the read sources; their cancel handlers close the read fds once
            // any in-flight handler has returned, so close() is race-free.
            outSrc?.cancel()
            errSrc?.cancel()
            if doTerminate {
                // Existing teardown policy: SIGTERM the immediate child, then SIGKILL
                // after a grace window if it is still running. Only the immediate
                // child is signaled (descendants are reclaimed via fd closure / their
                // own lifecycle), matching prior behavior.
                if process.isRunning {
                    process.terminate()
                    CommandRunner.scheduleSigkill(process)
                }
            }
        }
    }

    /// Buffers parent `Task` cancellation between `withTaskCancellationHandler`'s
    /// synchronous `onCancel` and the `install` of the capture's cancel action.
    /// Cancellation that arrives before the action is armed (during spawn) is
    /// recorded `pending` and fired the instant `install` registers the action;
    /// cancellation after `install` fires it immediately. Either way the capture's
    /// idempotent `claimImmediate` guarantees exactly-once resolution.
    private final class CancelBox: @unchecked Sendable {
        private struct State: Sendable {
            var action: (@Sendable () -> Void)?
            var pending = false
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())

        func install(_ action: @escaping @Sendable () -> Void) {
            let toFire = lock.withLock { state -> (@Sendable () -> Void)? in
                state.action = action
                if state.pending {
                    state.pending = false
                    return action
                }
                return nil
            }
            toFire?()
        }

        func trigger() {
            let toFire = lock.withLock { state -> (@Sendable () -> Void)? in
                if let action = state.action {
                    state.action = nil
                    return action
                }
                state.pending = true
                return nil
            }
            toFire?()
        }
    }

    // MARK: helpers

    private static func scheduleSigkill(_ process: Process) {
        let timer = CommandTimer(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            // Only SIGKILL if the Process is still running. If it already exited during
            // the grace window, sending to the bare pid could hit an unrelated process
            // that reused it; Foundation's `isRunning` confirms the pid is still ours.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Resolves `executable` to an absolute path, searching `PATH`, the bundled
    /// bin directory, and the fallback directories. Returns `nil` when nothing
    /// executable is found (the caller then runs it via `/usr/bin/env`).
    ///
    /// Internal rather than private so the resolution policy can be unit-tested
    /// directly with an injected environment and fallback directories.
    func resolvedCommandPath(executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        appendSearchPath(bundledBinPath)
        fallbackSearchDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
