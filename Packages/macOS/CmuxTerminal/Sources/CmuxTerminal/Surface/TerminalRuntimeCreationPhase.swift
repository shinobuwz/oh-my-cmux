/// User-observable lifecycle of one terminal's native runtime creation.
public enum TerminalRuntimeCreationPhase: Equatable, Sendable {
    /// No runtime creation is currently in progress.
    case idle
    /// The shared native runtime creation path is running.
    case creating
    /// A native runtime surface is available.
    case ready
    /// Native runtime creation failed and can be retried by the user.
    case failed
}
