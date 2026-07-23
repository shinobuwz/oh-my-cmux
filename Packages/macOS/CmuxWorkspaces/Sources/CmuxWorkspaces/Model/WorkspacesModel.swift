public import Foundation
public import Observation

/// The per-window workspace hierarchy model.
///
/// Group, container, and workspace arrays define the canonical order at each
/// sidebar level. Existing workspace objects remain the selected terminal hosts.
/// The owning `TabManager` composition root forwards legacy accessors and
/// receives synchronous mutation hooks through ``WorkspacesHosting``.
@MainActor
@Observable
public final class WorkspacesModel<Tab: WorkspaceTabRepresenting> {
    /// The window's workspaces in sidebar order.
    public var tabs: [Tab] = [] {
        willSet { host?.workspaceTabsWillChange(to: newValue) }
    }

    /// Independent top-level groups in sidebar order.
    public var workspaceGroups: [WorkspaceGroup] = [] {
        willSet { host?.workspaceGroupsWillChange(to: newValue) }
    }

    /// Second-level root containers in sidebar order.
    public var workspaceContainers: [WorkspaceContainer] = [] {
        willSet { host?.workspaceContainersWillChange(to: newValue) }
    }

    /// The selected workspace's id, if any.
    public var selectedTabId: UUID? {
        willSet { host?.selectedWorkspaceIdWillChange(to: newValue) }
        didSet { host?.selectedWorkspaceIdDidChange(from: oldValue) }
    }

    @ObservationIgnored
    private weak var host: (any WorkspacesHosting<Tab>)?

    /// Creates an empty model; the owning window attaches itself as host
    /// before the first mutation.
    public init() {}

    /// Attaches the window-side host. Must be called before the first
    /// mutation so the property-observer hooks match the legacy `@Published`
    /// timing from the very first workspace insertion.
    public func attach(host: any WorkspacesHosting<Tab>) {
        self.host = host
    }
}
