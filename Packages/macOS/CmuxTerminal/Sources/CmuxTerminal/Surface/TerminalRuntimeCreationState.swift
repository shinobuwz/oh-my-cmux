public import Observation

/// Observable child state for one terminal's native runtime creation.
///
/// `TerminalSurface` owns this model so creation failures can update the panel
/// without adding another Combine publisher to the latency-sensitive surface.
@MainActor
@Observable
public final class TerminalRuntimeCreationState {
    /// The current native runtime creation phase.
    public internal(set) var phase: TerminalRuntimeCreationPhase

    /// Creates state in the idle phase.
    public init(phase: TerminalRuntimeCreationPhase = .idle) {
        self.phase = phase
    }
}
