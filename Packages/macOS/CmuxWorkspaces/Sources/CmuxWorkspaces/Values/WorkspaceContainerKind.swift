public import Foundation

/// Classifies how a workspace container is bound to an execution root.
public enum WorkspaceContainerKind: String, Codable, CaseIterable, Sendable {
    /// A local Git repository with one or more managed worktrees.
    case git
    /// A local directory without Git worktree management.
    case localDirectory
    /// A remote session identified by a host and remote path.
    case remoteSession
    /// A local session whose restored surfaces have no reliable directory.
    case localSession
}
