/// An in-flight request to resolve a directory's watched-path descriptor
/// (the set of git paths the filesystem watcher should observe).
///
/// `generation` is a monotonically increasing stamp so a stale resolution
/// (the directory changed while paths were being resolved off-main) is
/// dropped instead of installing a watcher for the wrong directory.
struct WorkspaceGitMetadataWatcherDescriptorRequest: Equatable, Sendable {
    let generation: UInt64
    let directory: String
}

/// One service-side handle on a shared registry subscription: the
/// `@MainActor` listener task that pumps events into the service's
/// per-probe-key fan-out, and the registry token to release when the last
/// probe key detaches from this watched-paths key.
///
/// Both parts are ``Sendable`` — the token is a value type and the task is
/// `Sendable` — so the entry can be stored in a `@MainActor` dictionary and
/// released asynchronously from a detached task without capturing the
/// service.
struct WorkspaceGitMetadataWatcherSubscription {
    let listenerTask: Task<Void, Never>
    let token: WorkspaceGitMetadataWatcherSubscriptionToken
}
