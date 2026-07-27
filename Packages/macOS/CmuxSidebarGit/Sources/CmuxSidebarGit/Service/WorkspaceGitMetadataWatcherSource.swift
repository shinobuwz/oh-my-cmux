public import Foundation
internal import CmuxFoundation

/// One coalesced batch of filesystem changes the registry fans out to every
/// subscriber on a shared path set.
///
/// Mirrors ``RecursivePathWatcherEvent`` so the production source remains a
/// thin pass-through; deterministic test sources emit instances directly
/// without any real filesystem dependency.
public struct WorkspaceGitMetadataWatcherEvent: Sendable, Equatable {
    /// Every absolute path reported during the coalescing window.
    public let changedPaths: Set<String>
    /// Absolute paths whose containing directory was renamed, created, or
    /// removed (structural change) during the coalescing window.
    public let structurallyChangedPaths: Set<String>
    /// `true` when the underlying watcher asked for a full rescan (for
    /// example, after the volume was remounted).
    public let requiresFullRescan: Bool

    public init(
        changedPaths: Set<String> = [],
        structurallyChangedPaths: Set<String> = [],
        requiresFullRescan: Bool = false
    ) {
        self.changedPaths = changedPaths
        self.structurallyChangedPaths = structurallyChangedPaths
        self.requiresFullRescan = requiresFullRescan
    }
}

/// A factory + owner of one shared filesystem event source for an exact
/// normalized path set.
///
/// Package-internal: only ``WorkspaceGitMetadataWatcherRegistry`` depends on
/// this protocol. The production adapter alone constructs and consumes
/// `RecursivePathWatcher.events`; tests inject a deterministic fake.
protocol WorkspaceGitMetadataWatcherSource: Sendable {
    /// A stream of coalesced change batches for this source's path set.
    /// Finishes when ``stop()`` is called (or the source is deallocated).
    ///
    /// There is exactly one consumer per source — the registry's per-entry
    /// pump — so consumer pull cycles never contend.
    var events: AsyncStream<WorkspaceGitMetadataWatcherEvent> { get }

    /// Stops the underlying event source if it is still running. Idempotent.
    func stop() async
}

/// The production ``WorkspaceGitMetadataWatcherSource``: wraps exactly one
/// shared ``RecursivePathWatcher`` for the registered path set and translates
/// its event type.
///
/// Only this adapter touches `RecursivePathWatcher.events`; the registry and
/// the sidebar service never reference `RecursivePathWatcher` directly. That
/// keeps the registry source-agnostic and lets deterministic tests inject a
/// fake without depending on the real `FSEventStream` machinery.
struct RecursivePathWatcherSource: WorkspaceGitMetadataWatcherSource {
    private let watcher: RecursivePathWatcher
    let events: AsyncStream<WorkspaceGitMetadataWatcherEvent>

    init?(paths: [String]) {
        guard let watcher = RecursivePathWatcher(paths: paths) else { return nil }
        self.watcher = watcher

        // Bridge the source event type into the registry's event type. The
        // translation stream owns exactly one consumer (the registry's pump)
        // and finishes when the underlying watcher's events stream finishes
        // (stop or deallocation). The pump task is cancelled if the
        // translation consumer is cancelled, which lets the registry tear the
        // entry down without leaking the bridge task.
        let rawEvents = watcher.events
        let (translated, continuation) = AsyncStream<WorkspaceGitMetadataWatcherEvent>.makeStream()
        self.events = translated
        let bridge = Task {
            for await raw in rawEvents {
                continuation.yield(
                    WorkspaceGitMetadataWatcherEvent(
                        changedPaths: raw.changedPaths,
                        structurallyChangedPaths: raw.structurallyChangedPaths,
                        requiresFullRescan: raw.requiresFullRescan
                    )
                )
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            bridge.cancel()
        }
    }

    func stop() async {
        await watcher.stop()
    }
}
