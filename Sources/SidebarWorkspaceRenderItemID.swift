import Foundation

/// Stable, allocation-free identity for one drawable sidebar hierarchy item.
struct SidebarWorkspaceRenderItemID: Hashable {
    private let kind: UInt8
    private let uuid: UUID

    static func group(_ uuid: UUID) -> Self { Self(kind: 1, uuid: uuid) }
    static func container(_ uuid: UUID) -> Self { Self(kind: 2, uuid: uuid) }
    static func workspace(_ uuid: UUID) -> Self { Self(kind: 3, uuid: uuid) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(uuid)
    }
}
