import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case diff
    case feed
    case dock
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .diff: return String(localized: "rightSidebar.mode.diff", defaultValue: "Diff")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .diff: return "doc.text.magnifyingglass"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .diff: return nil
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}

enum RightSidebarContentMountPolicy {
    static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}

enum FileExplorerRootSyncPolicy {
    static func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch mode {
        case .files, .find, .diff:
            return true
        case .sessions, .feed, .dock, .customSidebar:
            return false
        }
    }
}

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        modeShortcut(for: event, allowingAction: { _ in true })
    }

    static func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        for mode in RightSidebarMode.allCases {
            guard let action = mode.shortcutAction,
                  allowingAction(action),
                  mode.isAvailable(),
                  KeyboardShortcutSettings.shortcut(for: action).matches(event: event) else {
                continue
            }
            return mode
        }
        return nil
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let titlebarHeight: CGFloat
    let windowAppearance: WindowAppearanceSnapshot
    let workspaceId: UUID?
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onClose: () -> Void

    @State private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @State private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var hasMountedRightSidebarContent = false
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private let closeShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let closeShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY
    private let focusShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintX
    private let focusShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintY
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(RightSidebarBetaFeatureSettings.feedEnabledKey)
    private var feedEnabled = RightSidebarBetaFeatureSettings.defaultFeedEnabled
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var dockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    private var availableModes: [RightSidebarMode] {
        RightSidebarMode.availableModes(feedEnabled: feedEnabled, dockEnabled: dockEnabled)
    }

    private var modeBarItems: [RightSidebarModeBarItem] {
        availableModes.map { RightSidebarModeBarItem(kind: .mode($0)) }
    }

    private var focusShortcutHintAnimationValue: Bool {
        alwaysShowShortcutHints || (showModifierHoldHints && focusShortcutHintMonitor.isModifierPressed)
    }

    private func startShortcutHintMonitorsIfNeeded() {
        guard showModifierHoldHints else {
            stopShortcutHintMonitors()
            return
        }
        modeShortcutHintMonitor.start()
        focusShortcutHintMonitor.start()
        closeShortcutHintMonitor.start()
    }

    private func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
                .rightSidebarChromeBottomBorder()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintAnimationValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                let hintWindow = showModifierHoldHints ? window : nil
                modeShortcutHintMonitor.setHostWindow(hintWindow)
                focusShortcutHintMonitor.setHostWindow(hintWindow)
                closeShortcutHintMonitor.setHostWindow(hintWindow)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            startShortcutHintMonitorsIfNeeded()
            if fileExplorerState.isVisible { hasMountedRightSidebarContent = true }
            fileExplorerState.refreshModeAvailability()
        }
        .onDisappear {
            stopShortcutHintMonitors()
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startShortcutHintMonitorsIfNeeded()
        }
        .onChange(of: fileExplorerState.isVisible) { _, visible in
            if visible { hasMountedRightSidebarContent = true }
        }
        .onChange(of: feedEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
        .onChange(of: dockEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        return ZStack {
            WindowDragHandleView()

            HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
                ForEach(modeBarItems) { item in
                    let shortcut = item.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) } ?? .unbound
                    ModeBarButton(
                        item: item,
                        isSelected: item.isSelected(
                            mode: fileExplorerState.mode
                        ),
                        badgeCount: item.mode == .feed ? feedPendingCount : 0,
                        shortcutHint: shortcut,
                        showsShortcutHint: ShortcutHintTitlebarPolicy.shouldShow(
                            shortcut: shortcut,
                            alwaysShowShortcutHints: alwaysShowShortcutHints,
                            modifierPressed: modeShortcutHintMonitor.isModifierPressed,
                            modifierHoldHintsEnabled: showModifierHoldHints
                        )
                    ) {
                        let mode = item.mode
                        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                            mode: mode,
                            focusFirstItem: true,
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        ) != true {
                            selectMode(mode)
                        }
                    }
                }

                Spacer(minLength: 0)
                if fileExplorerState.mode.canOpenAsPane {
                    openAsPaneButton(mode: fileExplorerState.mode)
                }
                closeButton
            }
        }
        .rightSidebarChromeBar(leadingPadding: 4, trailingPadding: 6, height: titlebarHeight)
        .overlay(alignment: .topLeading) {
            focusShortcutHintOverlay
        }
        .background(TitlebarDoubleClickMonitorView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebarModeBar")
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            isVisible: true,
            titlebarHeight: titlebarHeight
        )
    }

    private func openAsPaneButton(mode: RightSidebarMode) -> some View {
        Button {
            onOpenAsPane(mode)
        } label: {
            HeaderChromeIconStyle.symbol("rectangle.split.2x1")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderOpenAsPaneIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarHeaderOpenAsPane",
            isVisible: true
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                mode.label
            )
        )
        .accessibilityIdentifier("RightSidebar.openAsPaneButton")
        .titlebarInteractiveControl()
    }

    private var closeButton: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        return ZStack {
            Button(action: onClose) {
                HeaderChromeIconStyle.symbol("xmark")
            }
            .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderCloseIcon"))
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: "rightSidebarHeaderClose",
                isVisible: true
            )
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
                )
            )
            .accessibilityLabel(String(localized: "rightSidebar.close.accessibilityLabel", defaultValue: "Close Right Sidebar"))
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .rightSidebarHeaderControlAlignment()
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .titlebarInteractiveControl()
    }
    private var openDiffButton: some View {
        Button {
            guard AppDelegate.shared?.openDirectoryDiffViewerForFocusedWorkspace(for: tabManager) == true else {
                NSSound.beep()
                return
            }
        } label: {
            HeaderChromeIconStyle.symbol("doc.text.magnifyingglass")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderDiffIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarHeaderDiff",
            isVisible: true
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "command.openDirectoryDiffViewer.title", defaultValue: "Open Directory Diff Viewer"))
        .accessibilityLabel(String(localized: "command.openDirectoryDiffViewer.title", defaultValue: "Open Directory Diff Viewer"))
        .accessibilityIdentifier("RightSidebar.openDiffButton")
        .titlebarInteractiveControl()
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let showsFocusShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        if showsFocusShortcutHint {
            ShortcutHintPill(
                shortcut: shortcut,
                fontSize: 9,
                emphasis: 1.05
            )
                .padding(.leading, 6)
                .padding(.top, 5)
                .offset(
                    x: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintXOffset)),
                    y: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintYOffset))
                )
                .shortcutHintTransition()
                .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        if RightSidebarContentMountPolicy.shouldMountContent(isRightSidebarVisible: fileExplorerState.isVisible, hasMountedContent: hasMountedRightSidebarContent) {
            switch fileExplorerState.mode {
            case .files:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .files
                )
            case .find:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .find
                )
            case .sessions:
                SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                    .onAppear {
                        sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                    }
            case .diff:
                GitDiffPanelView(directory: fileExplorerStore.rootPath, workspaceId: workspaceId)
            case .feed:
                FeedPanelView()
            case .dock:
                dockPanel(windowAppearance: windowAppearance)
            case .customSidebar:
                EmptyView()
            }
        } else {
            Color.clear
        }
    }

    private var sessionIndexDirectory: String? {
        sessionIndexStore.currentDirectory
    }

    /// Renders this window's own Dock (created lazily on first show); no
    /// window ever defers to a Dock rendered elsewhere.
    @ViewBuilder
    private func dockPanel(windowAppearance: WindowAppearanceSnapshot) -> some View {
        if let app = AppDelegate.shared, let dock = app.windowDock(for: tabManager) {
            DockPanelView(
                store: dock,
                isSidebarVisible: fileExplorerState.isVisible,
                mode: fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus
            )
            .id("dock.window.\(dock.workspaceId.uuidString)")
        } else {
            Color.clear
        }
    }

    private func selectMode(_ mode: RightSidebarMode) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    private func refreshModeAvailabilityAndFocusIfNeeded() {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        let mode = fileExplorerState.mode
        // The Dock manages its own lifecycle from DockPanelView, so no dock sync
        // is needed here when the mode is unchanged.
        guard previousMode != mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}

private struct RightSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RightSidebarKeyboardFocusView {
        let view = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateNSView(_ nsView: RightSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
#if DEBUG
        dlog(
            "rs.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            dlog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}

private enum GitDiffFileStatus: String, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case conflicted
    case untracked

    var marker: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "U"
        case .untracked: return "?"
        }
    }

    var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .deleted, .conflicted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        }
    }
}

private struct GitDiffFileSnapshot: Identifiable, Sendable {
    let id: String
    let path: String
    let status: GitDiffFileStatus

    var basename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct GitDiffCommandOutput: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

@MainActor
private final class GitDiffSnapshotStore: ObservableObject {
    @Published private(set) var files: [GitDiffFileSnapshot] = []
    @Published private(set) var isGitRepository = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var directory = ""
    private var refreshTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var revision = 0
    private var refreshGeneration = 0

    deinit {
        refreshTask?.cancel()
        scanTask?.cancel()
    }

    func setDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != directory else { return }
        directory = normalized
        revision &+= 1
        refreshGeneration &+= 1
        refreshTask?.cancel()
        scanTask?.cancel()
        scanTask = nil
        files = []
        errorMessage = nil
        isGitRepository = false
        isLoading = false
        guard !normalized.isEmpty else { return }
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func refresh(force: Bool = false) {
        guard !directory.isEmpty else { return }
        if !force, isLoading { return }
        let path = directory
        let expectedRevision = revision
        refreshGeneration &+= 1
        let expectedGeneration = refreshGeneration
        scanTask?.cancel()
        isLoading = true
        scanTask = Task { [weak self] in
            let result = await GitDiffSnapshotStore.loadSnapshot(at: path)
            guard let self,
                  expectedRevision == self.revision,
                  expectedGeneration == self.refreshGeneration,
                  path == self.directory else { return }
            self.scanTask = nil
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                self.isGitRepository = true
                self.errorMessage = nil
                self.files = snapshot
            case .failure(let error):
                let isNotRepository = Self.isNotRepository(error)
                self.isGitRepository = !isNotRepository
                self.errorMessage = isNotRepository ? nil : error.localizedDescription
                self.files = []
            }
        }
    }

    nonisolated static func loadPatch(
        at directory: String,
        relativePath: String,
        status: GitDiffFileStatus
    ) async -> Result<String, NSError> {
        if status == .untracked {
            let result = await runGit(
                at: directory,
                arguments: [
                    "diff", "--no-index", "--no-ext-diff", "--no-color", "--unified=3",
                    "--", "/dev/null", relativePath
                ]
            )
            switch result {
            case .success(let output) where output.status == 0 || output.status == 1:
                return .success(String(decoding: output.standardOutput, as: UTF8.self))
            case .success(let output):
                return .failure(commandError(output, fallback: String(localized: "gitWorktrees.diff.patchFailed", defaultValue: "Git could not create a patch.")))
            case .failure(let error):
                return .failure(error)
            }
        }

        let headResult = await runGit(
            at: directory,
            arguments: ["diff", "HEAD", "--no-ext-diff", "--no-color", "--unified=3", "--", relativePath]
        )
        if case .success(let output) = headResult, output.status == 0 {
            return .success(String(decoding: output.standardOutput, as: UTF8.self))
        }

        guard case .success(let headOutput) = headResult,
              headOutput.status == 128 || headOutput.status == 129 else {
            if case .failure(let error) = headResult { return .failure(error) }
            if case .success(let output) = headResult {
                return .failure(commandError(output, fallback: String(localized: "gitWorktrees.diff.patchFailed", defaultValue: "Git could not create a patch.")))
            }
            return .failure(NSError(domain: "GitDiff", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "gitWorktrees.diff.patchFailed", defaultValue: "Git could not create a patch.")
            ]))
        }

        let stagedResult = await runGit(
            at: directory,
            arguments: ["diff", "--cached", "--no-ext-diff", "--no-color", "--unified=3", "--", relativePath]
        )
        let unstagedResult = await runGit(
            at: directory,
            arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", "--", relativePath]
        )
        var patch = Data()
        for result in [stagedResult, unstagedResult] {
            guard case .success(let output) = result, output.status == 0 else { continue }
            patch.append(output.standardOutput)
        }
        if !patch.isEmpty { return .success(String(decoding: patch, as: UTF8.self)) }
        if case .success(let output) = stagedResult, output.status != 0 {
            return .failure(commandError(output, fallback: String(localized: "gitWorktrees.diff.patchFailed", defaultValue: "Git could not create a patch.")))
        }
        if case .success(let output) = unstagedResult, output.status != 0 {
            return .failure(commandError(output, fallback: String(localized: "gitWorktrees.diff.patchFailed", defaultValue: "Git could not create a patch.")))
        }
        return .success("")
    }

    nonisolated private static func loadSnapshot(
        at directory: String
    ) async -> Result<[GitDiffFileSnapshot], NSError> {
        let result = await runGit(
            at: directory,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
        )
        switch result {
        case .success(let output) where output.status == 0:
            return .success(parseStatuses(output.standardOutput))
        case .success(let output):
            return .failure(commandError(output, fallback: String(localized: "gitWorktrees.diff.statusFailed", defaultValue: "Git status failed.")))
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated private static func parseStatuses(_ data: Data) -> [GitDiffFileSnapshot] {
        let records = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
        var files: [GitDiffFileSnapshot] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            let characters = Array(record)
            guard characters.count >= 4 else {
                index += 1
                continue
            }
            let indexCode = characters[0]
            let worktreeCode = characters[1]
            let path = String(record.dropFirst(3))
            index += 1
            if indexCode == "R" || indexCode == "C" || worktreeCode == "R" || worktreeCode == "C" {
                index += 1
            }
            guard !path.isEmpty, let status = status(index: indexCode, worktree: worktreeCode) else { continue }
            files.append(GitDiffFileSnapshot(id: path, path: path, status: status))
        }
        return files
    }

    nonisolated private static func status(index: Character, worktree: Character) -> GitDiffFileStatus? {
        if index == "?" && worktree == "?" { return .untracked }
        if index == "U" || worktree == "U" { return .conflicted }
        if index == "D" || worktree == "D" { return .deleted }
        if index == "R" || worktree == "R" { return .renamed }
        if index == "A" || worktree == "A" || index == "C" || worktree == "C" { return .added }
        if index == "M" || worktree == "M" || index == "T" || worktree == "T" { return .modified }
        return nil
    }

    nonisolated private static func runGit(
        at directory: String,
        arguments: [String]
    ) async -> Result<GitDiffCommandOutput, NSError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            return .failure(NSError(domain: "GitDiff", code: 1, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription
            ]))
        }

        let outputTask = Task.detached(priority: .utility) {
            standardOutput.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            standardError.fileHandleForReading.readDataToEndOfFile()
        }
        let output = await outputTask.value
        let error = await errorTask.value
        process.waitUntilExit()
        return .success(GitDiffCommandOutput(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: error
        ))
    }

    nonisolated private static func commandError(
        _ output: GitDiffCommandOutput,
        fallback: String
    ) -> NSError {
        let details = String(decoding: output.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(domain: "GitDiff", code: Int(output.status), userInfo: [
            NSLocalizedDescriptionKey: details.isEmpty ? fallback : details
        ])
    }

    nonisolated private static func isNotRepository(_ error: NSError) -> Bool {
        error.code == 128 || error.code == 129 ||
            error.localizedDescription.localizedCaseInsensitiveContains("not a git repository")
    }
}

private struct GitDiffPanelView: View {
    let directory: String
    let workspaceId: UUID?
    @StateObject private var store = GitDiffSnapshotStore()
    @State private var collapsedFolders: Set<String> = []
    @State private var selectedFilePath: String?
    @State private var openError: String?

    init(directory: String, workspaceId: UUID?) {
        self.directory = directory
        self.workspaceId = workspaceId
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if directory.isEmpty {
                GitDiffEmptyState(text: String(localized: "gitWorktrees.diff.noDirectory", defaultValue: "Select a workspace to view its diff."), symbol: "folder")
            } else if !store.isGitRepository && !store.isLoading {
                GitDiffEmptyState(text: String(localized: "gitWorktrees.diff.notRepository", defaultValue: "This workspace is not a Git repository."), symbol: "questionmark.folder")
            } else if let errorMessage = store.errorMessage, !store.isLoading {
                GitDiffEmptyState(
                    text: errorMessage,
                    symbol: "exclamationmark.triangle",
                    actionTitle: String(localized: "gitWorktrees.diff.retry", defaultValue: "Retry"),
                    action: { store.refresh(force: true) }
                )
            } else if store.isLoading && store.files.isEmpty {
                GitDiffEmptyState(text: String(localized: "gitWorktrees.diff.loading", defaultValue: "Loading changes…"), symbol: "arrow.triangle.2.circlepath")
            } else if store.files.isEmpty && !store.isLoading {
                GitDiffEmptyState(text: String(localized: "gitWorktrees.diff.clean", defaultValue: "No changes."), symbol: "checkmark.circle")
            } else {
                changesList
            }
        }
        .onAppear { store.setDirectory(directory) }
        .onChange(of: directory) { _, newValue in store.setDirectory(newValue) }
        .alert(
            String(localized: "gitWorktrees.diff.openError.title", defaultValue: "Unable to open diff"),
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )
        ) {
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? String(localized: "gitWorktrees.diff.openError.message", defaultValue: "The file diff could not be opened."))
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "gitWorktrees.diff.title", defaultValue: "Git Diff"))
                        .font(.system(size: 11, weight: .semibold))
                    if !directory.isEmpty {
                        Text(directoryDisplayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if store.isLoading { ProgressView().controlSize(.mini) }
                Button { store.refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(String(localized: "diffViewer.refresh", defaultValue: "Refresh"))
                .accessibilityLabel(String(localized: "diffViewer.refresh", defaultValue: "Refresh"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private var changesList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedFiles, id: \.folder) { group in
                    folderHeader(group)
                    if !collapsedFolders.contains(group.folder) {
                        ForEach(group.files) { file in
                            fileRow(file)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
    }

    private func folderHeader(_ group: (folder: String, files: [GitDiffFileSnapshot])) -> some View {
        let isCollapsed = collapsedFolders.contains(group.folder)
        let folderName = group.folder.isEmpty
            ? String(localized: "gitWorktrees.diff.rootFolder", defaultValue: "Repository root")
            : URL(fileURLWithPath: group.folder).lastPathComponent
        let parentPath = group.folder.isEmpty
            ? nil
            : {
                let parent = URL(fileURLWithPath: group.folder).deletingLastPathComponent()
                let parentPath = parent.path
                return parentPath == "." || parentPath == "/" ? nil : parentPath
            }()
        return Button {
            if isCollapsed { collapsedFolders.remove(group.folder) }
            else { collapsedFolders.insert(group.folder) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(folderName)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let parentPath {
                        Text(parentPath)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(String(group.files.count))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folderName)
        .accessibilityValue(isCollapsed ? String(localized: "gitWorktrees.diff.collapsed", defaultValue: "Collapsed") : String(localized: "gitWorktrees.diff.expanded", defaultValue: "Expanded"))
    }

    private func fileRow(_ file: GitDiffFileSnapshot) -> some View {
        Button {
            open(file: file)
        } label: {
            HStack(spacing: 6) {
                Text(file.status.marker)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(file.status.color)
                    .frame(width: 13)
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(file.basename)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
            .padding(.leading, 25)
            .padding(.trailing, 8)
            .background(selectedFilePath == file.path ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("GitDiff.file.\(file.path)")
        .accessibilityLabel(file.path)
        .help(file.path)
    }

    private var directoryDisplayName: String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private var groupedFiles: [(folder: String, files: [GitDiffFileSnapshot])] {
        Dictionary(grouping: store.files) { file in
            guard let slash = file.path.lastIndex(of: "/") else { return "" }
            return String(file.path[..<slash])
        }
        .map { (folder: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
        .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    private func open(file: GitDiffFileSnapshot) {
        selectedFilePath = file.path
        openError = nil
        guard let workspaceId else {
            openError = String(localized: "gitWorktrees.diff.openError.message", defaultValue: "The file diff could not be opened.")
            return
        }
        Task {
            let result = await GitDiffSnapshotStore.loadPatch(
                at: directory,
                relativePath: file.path,
                status: file.status
            )
            guard case .success(let patch) = result, !patch.isEmpty else {
                openError = result.failureMessage
                return
            }
            guard AppDelegate.shared?.launchPatchDiffViewerProcess(
                patch: patch,
                cwd: directory,
                workspaceId: workspaceId,
                focus: true
            ) == true else {
                openError = String(localized: "gitWorktrees.diff.openError.message", defaultValue: "The file diff could not be opened.")
                return
            }
        }
    }
}

private extension Result where Success == String, Failure == NSError {
    var failureMessage: String {
        switch self {
        case .success:
            return String(localized: "gitWorktrees.diff.noPatch", defaultValue: "No diff is available for this file.")
        case .failure(let error):
            return error.localizedDescription
        }
    }
}

private struct GitDiffEmptyState: View {
    let text: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(text: String, symbol: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.symbol = symbol
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
