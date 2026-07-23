import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceTerminalWorkingDirectoryFallbackTests {
    @Test func newTerminalSurfaceFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() throws {
        let workspace = Workspace()
        let sourcePaneId = try #require(
            workspace.bonsplitController.focusedPaneId,
            "Expected focused pane in new workspace"
        )

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/cmux-requested-tab-cwd-\(UUID().uuidString)"
        let sourcePanel = try #require(
            workspace.newTerminalSurface(
                inPane: sourcePaneId,
                focus: true,
                workingDirectory: requestedDirectory
            ),
            "Expected source terminal panel to be created"
        )

        #expect(sourcePanel.requestedWorkingDirectory == requestedDirectory)
        #expect(
            workspace.panelDirectories[sourcePanel.id] == nil,
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        #expect(
            workspace.currentDirectory == staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        let newTabPanel = try #require(
            workspace.newTerminalSurfaceInFocusedPane(focus: false),
            "Expected new terminal tab panel to be created"
        )

        #expect(
            newTabPanel.requestedWorkingDirectory == requestedDirectory,
            "Expected new terminal tab to inherit the selected source terminal's requested cwd when no reported cwd exists yet"
        )
    }
    @Test func replacementTerminalUsesBoundWorkspaceRoot() {
        let workspace = Workspace()
        let staleSelectedTerminalDirectory = "/tmp/cmux-last-selected-cwd-\(UUID().uuidString)"
        let boundRoot = "/tmp/cmux-bound-root-\(UUID().uuidString)"
        workspace.currentDirectory = staleSelectedTerminalDirectory
        workspace.boundRootPath = boundRoot

        let replacement = workspace.createReplacementTerminalPanel()

        #expect(
            replacement.requestedWorkingDirectory == boundRoot,
            "Expected a replacement terminal to start at its second-level workspace root instead of the last selected terminal cwd"
        )
    }

    @Test func newWorkspaceContainerStartsCollapsedAndSelectionPreservesIt() throws {
        let suiteName = "cmux.workspace-collapse-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            initialWorkingDirectory: "/tmp/cmux-container-root",
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        let workspace = try #require(manager.tabs.first)

        #expect(manager.workspaceContainers.first?.isCollapsed == true)
        manager.selectWorkspace(workspace)
        #expect(manager.workspaceContainers.first?.isCollapsed == true)
    }
}
