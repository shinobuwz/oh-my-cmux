public import Foundation

/// An independent top-level sidebar group containing workspace containers.
///
/// Groups have their own lifecycle and may remain empty. Container membership
/// lives on ``WorkspaceContainer/groupId``; selecting a group navigates to its
/// last active workspace leaf when that leaf still exists.
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    /// The group's stable identity.
    public let id: UUID
    /// The group's display name.
    public var name: String
    /// Whether the group's container rows are collapsed in the sidebar.
    public var isCollapsed: Bool
    /// Whether the group is pinned.
    public var isPinned: Bool
    /// The last active descendant workspace used when the header is selected.
    public var lastActiveWorkspaceId: UUID?
    /// Group-level color override as a hexadecimal string.
    public var customColor: String?
    /// SF symbol name for the header icon. When nil, defaults to `folder.fill`.
    public var iconSymbol: String?

    /// Creates an independent workspace group.
    ///
    /// - Parameters:
    ///   - id: Stable group identity.
    ///   - name: User-visible name.
    ///   - isCollapsed: Initial disclosure state.
    ///   - isPinned: Whether the group belongs to the pinned tier.
    ///   - lastActiveWorkspaceId: Initial active descendant workspace, if any.
    ///   - customColor: Optional hexadecimal color override.
    ///   - iconSymbol: Optional SF symbol override.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        lastActiveWorkspaceId: UUID?,
        customColor: String?,
        iconSymbol: String?
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.lastActiveWorkspaceId = lastActiveWorkspaceId
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
