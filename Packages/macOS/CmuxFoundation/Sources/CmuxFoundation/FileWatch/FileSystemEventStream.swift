import CoreServices
import Foundation

/// A thin owner of an `FSEventStream` that reports raw filesystem events through
/// a `@Sendable` sink.
///
/// `FSEventStream` is a C API with no async-native replacement, and it is the
/// only macOS primitive that watches a *set of paths recursively* with a single
/// coalescing stream (a `DispatchSource` file source watches one descriptor and
/// does not recurse). It stays hidden behind this type; consumers
/// (``RecursivePathWatcher``) observe events only via the watcher's
/// `AsyncStream`. The stream is configured for file-level events.
///
/// **Threading.** Every instance shares one serial dispatch queue (rather than
/// one queue per stream) to bound thread usage when many workspaces are tracked.
/// All mutable state is touched only on that queue, which is why the type is
/// `@unchecked Sendable`. ``onEvent`` fires on the shared queue, so it MUST be
/// non-blocking — a slow sink would serialize behind every other stream's
/// teardown. The production sink only spawns a `Task` and returns.
///
/// **Context lifetime.** The stream is registered with FSEvents as its own
/// context `info` pointer, passed *unretained* (no `retain`/`release` callbacks).
/// That is safe because ``stop()`` invalidates the stream synchronously on the
/// shared queue before `deinit` returns: FSEvents delivers callbacks on that
/// same serial queue, so any in-flight or already-enqueued callback runs to
/// completion before the `queue.sync` teardown block, and none is delivered
/// after `FSEventStreamInvalidate`. No callback ever touches a freed instance,
/// so a separately retained context box is unnecessary.
final class FileSystemEventStream: @unchecked Sendable {
    private static let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.cmux.recursive-path-watcher", qos: .utility)
        queue.setSpecific(key: queueSpecificKey, value: 1)
        return queue
    }()
    /// Process-global count of `FSEventStream` instances this type has started but
    /// not yet stopped. Incremented exactly once after a successful
    /// `FSEventStreamStart` and decremented exactly once in the idempotent
    /// `stop()`/release path (see ``stop()``). Exposed for diagnostics through
    /// ``RecursivePathWatcher/activeStreamCount``.
    private static let activeStreamCounter = AtomicUInt64Counter()

    /// The process-wide number of currently active, owned `FSEventStream`
    /// instances — a best-effort diagnostic snapshot. See
    /// ``RecursivePathWatcher/activeStreamCount``.
    internal static var activeStreamCount: UInt64 {
        activeStreamCounter.loadRelaxed()
    }

    /// The C trampoline `FSEventStreamCreate` requires.
    ///
    /// It must be a context-free `@convention(c)` function pointer, so it cannot
    /// be an instance method (which would be curried over `self`). The owning
    /// stream is recovered from the context's `info` pointer instead — passed
    /// *unretained* (see the type's "Context lifetime" note), so this uses
    /// `takeUnretainedValue()` and never adjusts the reference count.
    private static let callback: FSEventStreamCallback = { _, info, eventCount, rawPaths, eventFlags, _ in
        guard let info else { return }
        let owner = Unmanaged<FileSystemEventStream>.fromOpaque(info).takeUnretainedValue()
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var changedPaths = Set<String>()
        var structurallyChangedPaths = Set<String>()
        var requiresFullRescan = false

        let structuralMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemCloned
        )
        let fullRescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
        )

        for index in 0..<Int(eventCount) {
            let path = String(cString: paths[index])
            let flags = eventFlags[index]
            changedPaths.insert(path)
            if flags & structuralMask != 0 {
                structurallyChangedPaths.insert(path)
            }
            if flags & fullRescanMask != 0 {
                requiresFullRescan = true
            }
        }
        guard !changedPaths.isEmpty || requiresFullRescan else { return }
        owner.onEvent(RecursivePathWatcherEvent(
            changedPaths: changedPaths,
            structurallyChangedPaths: structurallyChangedPaths,
            requiresFullRescan: requiresFullRescan
        ))
    }

    /// The non-blocking sink invoked on the shared queue for each filesystem
    /// event batch, including its changed paths and structural-change flags.
    private let onEvent: @Sendable (RecursivePathWatcherEvent) -> Void
    private var stream: FSEventStreamRef?
    // True only between a successful `FSEventStreamStart` and the matching
    // `FSEventStreamStop`. Distinct from `stream != nil`: a stream that was
    // created but failed to start is released without ever being counted, so the
    // flag — not the pointer — gates the count decrement.
    private var isStreamActive = false

    /// Creates and starts a stream for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - latency: The FSEvents coalescing latency in seconds.
    ///   - onEvent: A non-blocking sink invoked on the shared queue for each
    ///     filesystem event batch.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started.
    ///
    /// On success the stream is registered with the process-global active-stream
    /// count exactly once (see ``RecursivePathWatcher/activeStreamCount``); a
    /// stream that fails to start is torn down without touching the count.
    init?(
        paths: [String],
        latency: TimeInterval,
        onEvent: @escaping @Sendable (RecursivePathWatcherEvent) -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        self.onEvent = onEvent
        self.stream = nil

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
        isStreamActive = true
        _ = Self.activeStreamCounter.incrementRelaxed()
    }

    /// Stops and tears down the stream. Idempotent.
    ///
    /// Teardown runs synchronously on the shared queue so it completes before the
    /// caller continues — critically, before `deinit` returns. An async hop could
    /// let the instance deallocate before the stream is invalidated, leaking the
    /// `FSEventStream`. The `getSpecific` check tears down inline when already on
    /// the queue, avoiding a deadlock.
    ///
    /// The process-global active-stream count (see
    /// ``RecursivePathWatcher/activeStreamCount``) is decremented exactly once —
    /// on the transition out of the active state — so repeated `stop()` calls and
    /// a `deinit` following an explicit stop never underflow it.
    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueSpecificKey) != nil {
            stopOnQueue()
        } else {
            Self.queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        guard let stream else { return }
        if isStreamActive {
            // A stream that was never started (creation succeeded, start failed)
            // is released below without ever being counted or stopped, so the
            // flag gates both the `FSEventStreamStop` and the decrement.
            isStreamActive = false
            FSEventStreamStop(stream)
            _ = Self.activeStreamCounter.decrementRelaxed()
        }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
