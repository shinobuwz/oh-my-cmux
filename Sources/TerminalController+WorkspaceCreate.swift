import Foundation

extension TerminalController {
    struct TaskCreateWorkspaceCandidate {
        let tabManager: TabManager
        let windowID: UUID?
    }

    struct TaskCreateWorkspaceResolution {
        let workspace: Workspace
        let candidate: TaskCreateWorkspaceCandidate
    }

    nonisolated static func v2ExpandedWorkingDirectory(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private enum WorkspaceNewWorktreeOutcome: Sendable {
        case created(workspaceID: UUID, containerID: UUID, path: String?)
        case failed(code: String, message: String)
    }

    nonisolated func v2WorkspaceNewWorktree(params: [String: Any]) -> V2CallResult {
        guard let rawBranch = params["branch"] as? String else {
            return .err(code: "invalid_params", message: "Missing branch", data: nil)
        }
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            return .err(code: "invalid_params", message: "Branch must not be empty", data: nil)
        }

        let rawContainerID = params["container_id"] as? String
        let rawWorkspaceID = params["workspace_id"] as? String
        let rawWindowID = params["window_id"] as? String
        if let rawContainerID, UUID(uuidString: rawContainerID) == nil {
            return .err(code: "invalid_params", message: "container_id must be a UUID", data: nil)
        }
        if let rawWorkspaceID, UUID(uuidString: rawWorkspaceID) == nil {
            return .err(code: "invalid_params", message: "workspace_id must be a UUID", data: nil)
        }
        if let rawWindowID, UUID(uuidString: rawWindowID) == nil {
            return .err(code: "invalid_params", message: "window_id must be a UUID", data: nil)
        }

        let requestedFocus = params["focus"] as? Bool ?? false
        let focus = requestedFocus && Self.socketCommandAllowsInAppFocusMutations()
        let outcome: WorkspaceNewWorktreeOutcome? = socketAwaitCallback(timeout: 120) { finish in
            Task { @MainActor [weak self] in
                guard let self else {
                    finish(.failed(code: "unavailable", message: "Workspace context is unavailable"))
                    return
                }
                var routingParams: [String: Any] = [:]
                if let rawWorkspaceID { routingParams["workspace_id"] = rawWorkspaceID }
                if let rawWindowID { routingParams["window_id"] = rawWindowID }
                guard let tabManager = self.v2ResolveTabManager(params: routingParams) else {
                    finish(.failed(code: "unavailable", message: "Workspace context is unavailable"))
                    return
                }
                let containerID = rawContainerID.flatMap(UUID.init(uuidString:))
                    ?? rawWorkspaceID.flatMap(UUID.init(uuidString:)).flatMap { workspaceID in
                        tabManager.tabs.first(where: { $0.id == workspaceID })?.workspaceContainerId
                    }
                    ?? tabManager.selectedWorkspace?.workspaceContainerId
                guard let containerID else {
                    finish(.failed(code: "not_found", message: "Workspace container not found"))
                    return
                }
                do {
                    let workspace = try await tabManager.createManagedWorktree(
                        inContainer: containerID,
                        branch: branch,
                        select: focus
                    )
                    finish(.created(
                        workspaceID: workspace.id,
                        containerID: containerID,
                        path: workspace.boundRootPath
                    ))
                } catch let error as ManagedWorktreeMutationError {
                    let failure = Self.workspaceNewWorktreeFailure(error)
                    finish(.failed(code: failure.code, message: failure.message))
                } catch {
                    finish(.failed(code: "creation_failed", message: "Worktree creation failed"))
                }
            }
        }

        guard let outcome else {
            return .err(code: "timeout", message: "Worktree creation timed out", data: nil)
        }
        switch outcome {
        case let .created(workspaceID, containerID, path):
            return .ok([
                "workspace_id": workspaceID.uuidString,
                "container_id": containerID.uuidString,
                "path": v2OrNull(path),
                "focused": focus,
            ])
        case let .failed(code, message):
            return .err(code: code, message: message, data: nil)
        }
    }

    private nonisolated static func workspaceNewWorktreeFailure(
        _ error: ManagedWorktreeMutationError
    ) -> (code: String, message: String) {
        switch error {
        case .missingContainer:
            return ("not_found", "Workspace container not found")
        case .notGitContainer:
            return ("not_git", "Workspace does not support Git worktrees")
        case .unbornRepository:
            return ("unborn_repository", "The repository needs an initial commit before creating a worktree")
        case .mainWorktree:
            return ("main_worktree", "The main worktree cannot be replaced")
        case .unmanagedWorktree:
            return ("unmanaged_worktree", "The worktree is not managed by cmux")
        case .missingManagedBranch:
            return ("missing_branch", "The managed worktree branch is missing")
        case .crossWindowReference:
            return ("in_use", "The worktree is open in another window")
        case .git(let gitError):
            switch gitError {
            case .invalidBranchName(let name):
                return ("invalid_branch", "Invalid branch name: \(name)")
            case .filesystemFailure(let operation, let detail):
                return ("filesystem_failed", "\(operation): \(detail)")
            case .commandFailed(let command, _, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return ("git_failed", detail.isEmpty ? "\(command) failed" : detail)
            }
        }
    }

    // Shared workspace-create implementation: the workspace.create command moved
    // to ControlCommandCoordinator, but v2MobileWorkspaceCreate still drives
    // this body for the mobile data-plane create path.
    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]? = nil,
        idempotencyCache: WorkspaceCreateIdempotencyCache? = nil
    ) -> V2CallResult {
        let outcome = v2PrepareWorkspaceCreate(
            params: params,
            tabManager: resolvedTabManager,
            taskCreateCandidates: taskCreateCandidates,
            idempotencyCache: idempotencyCache
        )
        let preparation: WorkspaceCreatePreparation
        switch outcome {
        case let .failure(result):
            return result
        case let .existing(resolution):
            return workspaceCreateResult(
                workspace: resolution.workspace,
                windowID: resolution.candidate.windowID
            )
        case let .completed(_, operationID):
            return .err(
                code: "already_completed",
                message: "workspace.create operation already completed",
                data: ["operation_id": operationID.uuidString]
            )
        case let .ready(ready):
            preparation = ready
        }
        let workingDirectory = Self.v2ExpandedWorkingDirectory(
            v2RawString(params, "working_directory")
        )
        let execution: WorkspaceCreateExecutionPreparation
        switch v2PrepareWorkspaceCreateExecution(
            params: params,
            preparation: preparation,
            workingDirectory: workingDirectory
        ) {
        case let .failure(result):
            return result
        case let .ready(ready):
            execution = ready
        }
        return v2PerformWorkspaceCreate(
            preparation: preparation,
            execution: execution
        )
    }

    private func v2PerformWorkspaceCreate(
        preparation: WorkspaceCreatePreparation,
        execution: WorkspaceCreateExecutionPreparation,
        operationAlreadyAccepted: Bool = false
    ) -> V2CallResult {
        let tabManager = preparation.tabManager
        let operationID = preparation.operationID

        var newWorkspace: Workspace?
        if let operationID, !operationAlreadyAccepted {
            // Acceptance must be durable before addWorkspace constructs a
            // terminal and can execute the task command. A crash in between
            // intentionally favors at-most-once startup over workspace recovery.
            do {
                try preparation.idempotencyCache.accept(operationID: operationID)
            } catch {
                workspaceCreateIdempotencyLogger.error(
                    "Task reservation failed: \(String(describing: error), privacy: .private)"
                )
                return .err(
                    code: "persistence_failed",
                    message: "Workspace task could not be reserved safely",
                    data: nil
                )
            }
        }
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: execution.title,
                workingDirectory: execution.workingDirectory,
                initialTerminalCommand: execution.layoutNode == nil ? execution.initialCommand : nil,
                initialTerminalEnvironment: execution.layoutNode == nil ? execution.initialEnvironment : [:],
                workspaceEnvironment: execution.workspaceEnvironment,
                select: execution.shouldFocus,
                eagerLoadTerminal: execution.shouldEagerLoadTerminal,
                autoRefreshMetadata: execution.shouldAutoRefreshMetadata
            )
            ws.taskCreateOperationID = operationID
            ws.setCustomDescription(execution.description)
            if let layoutNode = execution.layoutNode {
                ws.applyCustomLayout(
                    layoutNode,
                    baseCwd: execution.workingDirectory ?? ws.currentDirectory
                )
            }
            if let groupID = execution.groupID,
               let containerID = ws.workspaceContainerId {
                let targetContainers = tabManager.workspaceContainers.filter { $0.groupId == groupID }
                let targetIndex: Int
                switch execution.groupPlacement ?? .top {
                case .top:
                    targetIndex = 0
                case .end:
                    targetIndex = targetContainers.count
                case .afterCurrent:
                    targetIndex = execution.groupReferenceWorkspaceID
                        .flatMap { referenceID in tabManager.tabs.first(where: { $0.id == referenceID })?.workspaceContainerId }
                        .flatMap { referenceContainerID in targetContainers.firstIndex(where: { $0.id == referenceContainerID }) }
                        .map { $0 + 1 }
                        ?? targetContainers.count
                }
                tabManager.moveWorkspaceContainer(containerId: containerID, toGroup: groupID, toIndex: targetIndex)
            }
            newWorkspace = ws
        }

        guard let newWorkspace else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        if let operationID {
            preparation.idempotencyCache.associate(operationID: operationID, workspaceID: newWorkspace.id)
        }
        return workspaceCreateResult(
            workspace: newWorkspace,
            windowID: v2ResolveWindowId(tabManager: tabManager)
        )
    }

    private func workspaceCreateResult(
        workspace: Workspace,
        windowID: UUID?
    ) -> V2CallResult {
        let workspaceID = workspace.id
        let groupID = workspace.workspaceContainerId.flatMap { containerID in
            workspace.owningTabManager?.workspaceContainers.first(where: { $0.id == containerID })?.groupId
        }
        let surfaceID = workspace.focusedPanelId
        return .ok([
            "window_id": v2OrNull(windowID?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowID),
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            "group_id": v2OrNull(groupID?.uuidString),
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupID),
            "surface_id": v2OrNull(surfaceID?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID)
        ])
    }

    func v2WorkspaceCloudVMOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let beforeIds = Set(tabManager.tabs.map(\.id))
        let didStart = AppDelegate.shared?.performCloudVMAction(
            tabManager: tabManager,
            debugSource: "rpc.workspace.cloud_vm_open"
        ) ?? false
        let createdWorkspace = tabManager.tabs.first { workspace in
            !beforeIds.contains(workspace.id)
                && workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading })
        }

        guard didStart || createdWorkspace != nil else {
            return .err(code: "unavailable", message: "Cloud VM action could not be started", data: nil)
        }

        let workspace = createdWorkspace ?? tabManager.selectedWorkspace
        let workspaceId = workspace?.id
        let surfaceId = workspace?.focusedPanelId
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "started": didStart,
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": v2OrNull(workspaceId?.uuidString),
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(surfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    func v2WorkspaceCloudVMTerminalReady(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawWorkspaceId = v2RawString(params, "workspace_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceId = UUID(uuidString: rawWorkspaceId) else {
            return .err(code: "invalid_params", message: "workspace_id is required", data: nil)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }
        guard let command = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .err(code: "invalid_params", message: "initial_command is required", data: ["workspace_id": workspaceId.uuidString])
        }

        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
        guard let panel = workspace.replaceCloudVMLoadingSurfaceWithTerminal(
            workspaceId: workspaceId,
            initialCommand: command,
            focus: focus
        ) else {
            return .err(
                code: "not_found",
                message: "Cloud VM loading surface not found",
                data: ["workspace_id": workspaceId.uuidString]
            )
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": panel.id.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
        ])
    }

    func v2MobileWorkspaceCreate(
        params: [String: Any],
        workingDirectoryValidator: WorkspaceCreateWorkingDirectoryValidator? = nil,
        tabManager resolvedTabManager: TabManager? = nil,
        idempotencyCache: WorkspaceCreateIdempotencyCache? = nil
    ) async -> V2CallResult {
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let outcome = v2PrepareWorkspaceCreate(
            params: createParams,
            tabManager: resolvedTabManager,
            taskCreateCandidates: nil,
            idempotencyCache: idempotencyCache
        )
        let preparation: WorkspaceCreatePreparation
        switch outcome {
        case let .failure(result):
            return result
        case let .existing(resolution):
            return mobileWorkspaceCreateResult(
                resolution: resolution,
                params: createParams
            )
        case let .completed(_, operationID):
            return Self.v2MobileCompletedOperationResult(operationID: operationID)
        case let .ready(ready):
            preparation = ready
        }
        guard !Task.isCancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let rawWorkingDirectory: String?
        let isWorkingDirectoryProvided: Bool
        if v2HasNonNullParam(createParams, "working_directory") {
            rawWorkingDirectory = v2RawString(createParams, "working_directory")
            isWorkingDirectoryProvided = true
        } else if v2HasNonNullParam(createParams, "cwd") {
            guard let cwd = v2RawString(createParams, "cwd") else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            rawWorkingDirectory = cwd
            isWorkingDirectoryProvided = true
        } else {
            rawWorkingDirectory = nil
            isWorkingDirectoryProvided = false
        }
        let validator = workingDirectoryValidator ?? Self.v2ValidateMobileWorkingDirectory
        let validation = await validator(
            rawWorkingDirectory,
            isWorkingDirectoryProvided
        )
        guard !Task.isCancelled, validation != .cancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let workingDirectory: String?
        switch validation {
        case .notProvided:
            workingDirectory = nil
        case let .valid(path):
            workingDirectory = path
        case .invalid:
            return Self.v2InvalidWorkingDirectoryResult
        case .busy:
            return .err(
                code: "busy",
                message: "working_directory validation is busy",
                data: ["field": "working_directory"]
            )
        case .timedOut:
            return .err(
                code: "request_timeout",
                message: "working_directory validation timed out",
                data: ["field": "working_directory"]
            )
        case .cancelled:
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let execution: WorkspaceCreateExecutionPreparation
        switch v2PrepareWorkspaceCreateExecution(
            params: createParams,
            preparation: preparation,
            workingDirectory: workingDirectory
        ) {
        case let .failure(result):
            return result
        case let .ready(ready):
            execution = ready
        }
        var operationAlreadyAccepted = false
        switch await v2ReserveMobileWorkspaceCreate(preparation: preparation) {
        case .notRequired:
            break
        case .accepted:
            operationAlreadyAccepted = true
        case let .live(resolution):
            return mobileWorkspaceCreateResult(resolution: resolution, params: createParams)
        case let .failure(result):
            return result
        }
        let createResult = v2PerformWorkspaceCreate(
            preparation: preparation,
            execution: execution,
            operationAlreadyAccepted: operationAlreadyAccepted
        )
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which watches TabManager.tabsPublisher directly. Don't fire here.
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: preparation.tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }

    private func mobileWorkspaceCreateResult(
        resolution: TaskCreateWorkspaceResolution,
        params: [String: Any]
    ) -> V2CallResult {
        let workspaceID = resolution.workspace.id.uuidString
        var listParams = params
        listParams["workspace_id"] = workspaceID
        return v2MobileWorkspaceList(
            params: listParams,
            tabManager: resolution.candidate.tabManager,
            createdWorkspaceID: workspaceID
        )
    }
}
