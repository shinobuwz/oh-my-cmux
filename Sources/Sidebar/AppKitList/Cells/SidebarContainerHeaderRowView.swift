import AppKit
import CmuxFoundation

/// Compact AppKit second-level container header.
@MainActor
final class SidebarContainerHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarContainerHeaderTableCellView")

    private let backgroundView = NSView()
    private let chevronButton = SidebarHeaderGlyphButton()
    private let iconImageView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let plusButton = SidebarHeaderGlyphButton()
    private var model: SidebarContainerHeaderRowModel?
    private var actions: SidebarContainerHeaderRowActions?
    private var isPointerHovering = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 4
        addSubview(backgroundView)
        chevronButton.onClick = { [weak self] in self?.actions?.onToggleCollapsed() }
        addSubview(chevronButton)
        iconImageView.imageScaling = .scaleProportionallyDown
        addSubview(iconImageView)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        addSubview(nameField)
        plusButton.onClick = { [weak self] in self?.actions?.onTapPlus() }
        addSubview(plusButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: SidebarContainerHeaderRowModel, actions: SidebarContainerHeaderRowActions, isPointerHovering: Bool) {
        let changed = self.model != model || self.isPointerHovering != isPointerHovering
        self.model = model
        self.actions = actions
        self.isPointerHovering = isPointerHovering
        guard changed else { return }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent
        chevronButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: model.isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: GlobalFontMagnification.scaledSize(metrics.chevronFontSize, percent: percent),
            weight: .semibold
        )
        chevronButton.setAccessibilityLabel(model.isCollapsed
            ? String(localized: "workspaceContainer.expand.a11y", defaultValue: "Expand container")
            : String(localized: "workspaceContainer.collapse.a11y", defaultValue: "Collapse container"))
        iconImageView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: model.isGitCapable ? "folder" : "folder.badge.gearshape",
            pointSize: GlobalFontMagnification.scaledSize(metrics.iconFontSize, percent: percent),
            weight: .regular
        )
        iconImageView.contentTintColor = .secondaryLabelColor
        let brokenRootLabel = String(localized: "workspaceContainer.brokenRoot", defaultValue: "Broken Root")
        nameField.stringValue = model.isRootBroken ? "\(model.name) · \(brokenRootLabel)" : model.name
        nameField.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .regular
        )
        nameField.textColor = model.isRootBroken ? .systemOrange : (model.isActive ? .labelColor : NSColor.labelColor.withAlphaComponent(0.86))
        backgroundView.layer?.backgroundColor = model.isActive ? NSColor.labelColor.withAlphaComponent(0.055).cgColor : NSColor.clear.cgColor
        plusButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus",
            pointSize: GlobalFontMagnification.scaledSize(metrics.plusFontSize, percent: percent),
            weight: .medium
        )
        plusButton.setAccessibilityLabel(String(localized: "workspaceContainer.newWorktree.a11y", defaultValue: "New worktree"))
        plusButton.isHidden = !model.isGitCapable
        plusButton.setRevealed(model.isGitCapable && (isPointerHovering || model.isActive))
        setAccessibilityIdentifier("sidebarWorkspaceContainer.\(model.containerId.uuidString)")
        setAccessibilityLabel(model.name)
        needsLayout = true
    }

    func enforcePointerHovering(_ hovering: Bool) {
        isPointerHovering = hovering
        guard let model else { return }
        plusButton.setRevealed(model.isGitCapable && (hovering || model.isActive))
    }

    func selectionPreviewShouldIgnore(_ hitView: NSView) -> Bool {
        hitView === chevronButton || hitView.isDescendant(of: chevronButton) || hitView === plusButton || hitView.isDescendant(of: plusButton)
    }

    static func preferredHeight(model: SidebarContainerHeaderRowModel) -> CGFloat {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let nameFont = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(
                metrics.nameFontSize,
                percent: model.globalFontMagnificationPercent
            ),
            weight: .regular
        )
        let nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        let contentHeight = max(metrics.chevronFrame, metrics.iconFrame, metrics.plusFrame, nameLineHeight)
        return ceil(contentHeight + (model.isCollapsed ? 4 : 10))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, actions != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "workspaceContainer.delete", defaultValue: "Delete Workspace"), action: #selector(deleteContainer), keyEquivalent: "")
        if model.isRootBroken {
            menu.addItem(withTitle: String(localized: "workspaceContainer.locateRoot", defaultValue: "Locate Root"), action: #selector(locateRoot), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func deleteContainer() { actions?.onDelete() }
    @objc private func locateRoot() { actions?.onLocateRoot() }
    override func layout() {
        super.layout()
        guard let model else { return }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let pad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let bg = NSRect(x: pad, y: 0, width: max(0, bounds.width - pad * 2), height: bounds.height)
        backgroundView.frame = bg
        let contentMaxX = bg.maxX - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let midY = bounds.midY
        var x = bg.minX + model.indentation
        let chevronSide = metrics.chevronFrame
        chevronButton.frame = NSRect(x: x, y: midY - chevronSide / 2, width: chevronSide, height: chevronSide)
        x = chevronButton.frame.maxX + 4
        let iconSide = metrics.iconFrame
        iconImageView.frame = NSRect(x: x, y: midY - iconSide / 2, width: iconSide, height: iconSide)
        x = iconImageView.frame.maxX + 6
        let plusSide = metrics.plusFrame
        plusButton.frame = NSRect(x: contentMaxX - plusSide, y: midY - plusSide / 2, width: plusSide, height: plusSide)
        let nameHeight = nameField.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        nameField.frame = NSRect(x: x, y: midY - nameHeight / 2, width: max(0, plusButton.frame.minX - x - 5), height: nameHeight)
    }
}
