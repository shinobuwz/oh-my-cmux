import Foundation

extension TerminalController {
    /// Mobile-gated workspace-group creation that mirrors mobile workspace.create.
    func v2MobileWorkspaceGroupCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        let title = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false ? title ?? "" : ""

        var mutationError: V2CallResult?
        v2MainSync {
            guard tabManager.createWorkspaceGroup(name: name) != nil else {
                mutationError = .err(code: "not_created", message: "Group was not created", data: nil)
                return
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "title")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    /// Mobile-gated workspace-group mutations that mirror the desktop header menu.
    func v2MobileWorkspaceGroupAction(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "group_id"), let groupID = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let action = mobileWorkspaceGroupAction(params: params) else {
            return .err(
                code: "method_not_found",
                message: "Unsupported workspace group action for mobile",
                data: ["action": v2OrNull(v2RawString(params, "action"))]
            )
        }
        let title = mobileWorkspaceGroupActionTitle(params: params, action: action)
        if action == .rename, title == nil {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }

        var mutationError: V2CallResult?
        v2MainSync {
            guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else {
                mutationError = .err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupID.uuidString]
                )
                return
            }
            switch action {
            case .pin:
                tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: true)
            case .unpin:
                tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: false)
            case .rename:
                guard let title else {
                    mutationError = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                tabManager.renameWorkspaceGroup(groupId: groupID, name: title)
            case .ungroup:
                let containerCount = tabManager.workspaceContainers.lazy.filter { $0.groupId == groupID }.count
                guard containerCount == 0, tabManager.deleteWorkspaceGroup(groupId: groupID) else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: String(localized: "mobile.workspaceGroup.error.onlyEmptyRemove", defaultValue: "Only an empty group can be removed on mobile"),
                        data: ["group_id": groupID.uuidString]
                    )
                    return
                }
            case .delete:
                let containerCount = tabManager.workspaceContainers.lazy.filter { $0.groupId == groupID }.count
                guard containerCount == 0, tabManager.deleteWorkspaceGroup(groupId: groupID) else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: String(localized: "workspaceGroup.error.nonEmptyDelete", defaultValue: "A non-empty group cannot be deleted"),
                        data: ["group_id": groupID.uuidString]
                    )
                    return
                }
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "group_id")
        listParams.removeValue(forKey: "action")
        listParams.removeValue(forKey: "title")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    private func mobileWorkspaceGroupAction(params: [String: Any]) -> MobileWorkspaceGroupAction? {
        guard let rawAction = v2RawString(params, "action")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_"),
            !rawAction.isEmpty else {
            return nil
        }
        return MobileWorkspaceGroupAction(rawValue: rawAction)
    }

    private func mobileWorkspaceGroupActionTitle(
        params: [String: Any],
        action: MobileWorkspaceGroupAction
    ) -> String? {
        guard action == .rename else { return nil }
        guard let trimmed = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private enum MobileWorkspaceGroupAction: String {
    case pin
    case unpin
    case rename
    case ungroup
    case delete
}
