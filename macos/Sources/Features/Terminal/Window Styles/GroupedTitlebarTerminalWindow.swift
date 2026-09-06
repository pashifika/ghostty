import AppKit

/// `macos-titlebar-style = groups`: the window's native tabs are presented as one custom row of
/// named groups and ungrouped tabs beside the native window controls.
///
/// This window owns presentation only. Every live tab stays a native `NSWindow` inside the native
/// `NSWindowTabGroup`; organization semantics (membership, activation, movement, prompts, Undo)
/// are requested through the `TabOrganization` facade and rendered back from its presentation.
/// The row is an owned toolbar item and the native tab strip accessory is hidden through its
/// public `isHidden` property, which is the header seam verified by the feasibility probe.
final class GroupedTitlebarTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("GroupedTitlebarTerminal")
    private static let stripItemIdentifier = NSToolbarItem.Identifier("GroupedTitlebarTerminal.strip")

    /// The toolbar item view hosting group headers and tabs.
    private let strip = GroupedTabStrip()
    private var stripWidth: NSLayoutConstraint?

    /// Set by the controller once its window finished loading. A presentation read before that
    /// point would describe a window the controller has not finished attaching to its tab group.
    private var organizationAttached = false
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var contextClickMonitor: Any?

    /// The row has no room for the update pill; the terminal view shows update state instead,
    /// exactly like the `tabs` style.
    override var supportsUpdateAccessory: Bool { false }

    override var titlebarFont: NSFont? {
        didSet { strip.titleFont = titlebarFont }
    }

    /// A menu entry works independently of the system's toolbar-focus shortcut.
    @IBAction private func focusTabGroups(_ sender: Any?) {
        guard let owner = strip.window else { return }
        owner.makeKey()
        owner.makeFirstResponder(strip)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let contextClickMonitor { NSEvent.removeMonitor(contextClickMonitor) }
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // The strip replaces the title; the tabs carry their own titles.
        titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
        titlebarSeparatorStyle = .none

        strip.delegate = self
        strip.terminalWindow = self
        strip.showsCloseButtons = (NSApp.delegate as? AppDelegate)?.ghostty.config.macosTabCloseButton ?? true
        let width = strip.widthAnchor.constraint(equalToConstant: preferredStripWidth())
        width.isActive = true
        stripWidth = width
        strip.heightAnchor.constraint(equalToConstant: GroupedTabStrip.rowHeight).isActive = true

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: TabOrganization.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            },
            center.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] notification in
                self?.configDidChange(notification)
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
                self?.updateStripWidth()
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
                self?.updateStripWidth()
                self?.scheduleRefresh()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
                self?.updateStripWidth()
                self?.scheduleRefresh()
            },
        ]

        // In native fullscreen AppKit hosts the toolbar in its own window, whose event dispatch we
        // do not own. Context clicks that land on our strip there are taken before dispatch and the
        // menu opens on the next turn, outside the event fetch.
        contextClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, Self.isContextClick(event),
                  let eventWindow = event.window, eventWindow !== self, eventWindow === self.strip.window,
                  let item = self.strip.item(at: event) else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.strip.showContextMenu(for: item, with: event)
            }
            return nil
        }
    }

    /// Called by `TerminalController.windowDidLoad` after the content view and native tab-group
    /// bookkeeping are in place. Facade change notifications are ignored until then.
    func attachOrganization() {
        organizationAttached = true
        refresh()
    }

    /// The native tab buttons are hidden, so inline editing has nothing to attach to; the shared
    /// "Rename Tab..." item falls back to the existing title dialog.
    override func beginInlineTabTitleEdit(for targetWindow: NSWindow) -> Bool {
        false
    }

    /// Terminal surfaces can consume control-key equivalents before AppKit reaches the toolbar's
    /// first responder. Give only this strip's focused item its navigation keys first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let item = strip.window?.firstResponder as? GroupedStripItem,
           item.strip === strip,
           strip.handleKeyDown(event, on: item) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Toolbar routing skips context clicks and wheel events in custom views.
    /// Redirect only events targeting our items or scrolling viewport.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, event.window === self, strip.handleScrollWheel(event) {
            return
        }
        if Self.isContextClick(event), event.window === self, let item = strip.item(at: event) {
            strip.showContextMenu(for: item, with: event)
            return
        }
        super.sendEvent(event)
    }

    private static func isContextClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown: return true
        case .otherMouseDown: return event.buttonNumber == 2
        case .leftMouseDown: return event.modifierFlags.contains(.control)
        default: return false
        }
    }

    override func becomeMain() {
        super.becomeMain()
        scheduleRefresh()
    }

    override func resignMain() {
        super.resignMain()
        scheduleRefresh()
    }

    // MARK: Native Tab Bar Suppression

    /// The base class calls this predicate too. The only bottom accessory AppKit adds to a
    /// terminal window is the native tab strip, so no native view class is inspected.
    override func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool {
        childViewController.layoutAttribute == .bottom
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        if childViewController.layoutAttribute == .bottom {
            childViewController.isHidden = true
        }
        scheduleRefresh()
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        super.removeTitlebarAccessoryViewController(at: index)
        scheduleRefresh()
    }

    // MARK: Presentation

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Coalesce the bursts of KVO/notification traffic AppKit and the facade emit for one
        // native operation into a single render per turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard organizationAttached else { return }
        for accessory in titlebarAccessoryViewControllers
        where accessory.layoutAttribute == .bottom && !accessory.isHidden {
            accessory.isHidden = true
        }
        updateStripWidth()
        strip.render(TabOrganization.shared.presentation(for: self))
    }

    private func configDidChange(_ notification: Notification) {
        // Only the app-wide configuration carries the presentation setting.
        guard notification.object == nil,
              let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
        else { return }
        strip.showsCloseButtons = config.macosTabCloseButton
    }

    /// Fill the toolbar after its native window-control inset and outer margins.
    /// The strip's fixed new-tab button defines the trailing viewport boundary.
    private func preferredStripWidth() -> CGFloat {
        let leading: CGFloat = styleMask.contains(.fullScreen) ? 16 : 88
        let trailing: CGFloat = 16
        return max(160, frame.width - leading - trailing)
    }

    private func updateStripWidth() {
        let width = preferredStripWidth()
        if stripWidth?.constant != width {
            stripWidth?.constant = width
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.stripItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.stripItemIdentifier else {
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Tabs and Groups"
        item.paletteLabel = item.label
        item.visibilityPriority = .high
        item.view = strip
        // Documented way to avoid the glass container around a custom item view.
        item.isBordered = false
        return item
    }
}

// MARK: - GroupedTabStripDelegate

extension GroupedTitlebarTerminalWindow: GroupedTabStripDelegate {
    func strip(_ strip: GroupedTabStrip, perform action: TabOrganization.Action) {
        TabOrganization.shared.perform(action, in: self)
    }

    func stripPresentationForDrop(_ strip: GroupedTabStrip) -> TabOrganization.Presentation {
        TabOrganization.shared.flush()
        return TabOrganization.shared.presentation(for: self)
    }

    func strip(_ strip: GroupedTabStrip, contextMenuForTab tabID: UUID) -> NSMenu? {
        TabOrganization.shared.contextMenu(for: tabID, in: self)
    }

    func strip(_ strip: GroupedTabStrip, contextMenuForGroup groupID: UUID) -> NSMenu {
        TabOrganization.shared.groupContextMenu(for: groupID, in: self)
    }

    func stripDidRequestTerminalFocus(_ strip: GroupedTabStrip) {
        let selected = tabGroup?.selectedWindow?.windowController as? TerminalController
        guard let controller = selected ?? terminalController, let surface = controller.focusedSurface else { return }
        controller.window?.makeKey()
        controller.focusSurface(surface)
    }
}

/// Semantic requests the strip makes; the window forwards them to the organization facade.
@MainActor
protocol GroupedTabStripDelegate: AnyObject {
    func strip(_ strip: GroupedTabStrip, perform action: TabOrganization.Action)
    func stripPresentationForDrop(_ strip: GroupedTabStrip) -> TabOrganization.Presentation
    func strip(_ strip: GroupedTabStrip, contextMenuForTab tabID: UUID) -> NSMenu?
    func strip(_ strip: GroupedTabStrip, contextMenuForGroup groupID: UUID) -> NSMenu
    /// Keyboard focus leaves the strip and returns to this window's focused terminal surface.
    func stripDidRequestTerminalFocus(_ strip: GroupedTabStrip)
}

// MARK: - Strip

/// One horizontal row: a scrolling canvas of group headers and tabs, overflow controls,
/// and a fixed trailing new-tab button. Empty canvas space remains available for window dragging.
/// The strip renders facade state and never owns terminal lifecycle.
final class GroupedTabStrip: NSView {
    static let rowHeight: CGFloat = 28

    enum Metrics {
        static let itemHeight: CGFloat = 24
        static let cornerRadius: CGFloat = 12
        static let canvasInset: CGFloat = 2
        static let horizontalPadding: CGFloat = 8
        static let iconSpacing: CGFloat = 5
        static let colorDotSize: CGFloat = 7
        static let chevronWidth: CGFloat = 10
        static let closeButtonSize: CGFloat = 16
        static let tabMinLabelWidth: CGFloat = 36
        static let groupMinLabelWidth: CGFloat = 48
        static let groupMaxLabelWidth: CGFloat = 140
        static let memberSpacing: CGFloat = 3
        static let tabSpacing: CGFloat = 4
        static let sectionGap: CGFloat = 10
        static let separatorWidth: CGFloat = 1
        static let newTabButtonWidth: CGFloat = 28
        static let newTabButtonGap: CGFloat = 4
        static let scrollButtonWidth: CGFloat = 22
        static let dragThreshold: CGFloat = 4
        static let detachDistance: CGFloat = 28
        static let autoScrollMargin: CGFloat = 24
        static let autoScrollStep: CGFloat = 6
        static let revealMargin: CGFloat = 12
    }

    weak var delegate: GroupedTabStripDelegate?
    fileprivate weak var terminalWindow: TerminalWindow? {
        didSet { canvas.terminalWindow = terminalWindow }
    }

    /// `macos-tab-close-button`. Presentation only; reloading it relays out the existing items.
    var showsCloseButtons = true {
        didSet {
            guard showsCloseButtons != oldValue else { return }
            for item in tabItems.values { item.showsCloseButton = showsCloseButtons }
            needsLayout = true
        }
    }

    var titleFont: NSFont? {
        didSet {
            guard titleFont != oldValue else { return }
            for item in tabItems.values { item.titleFont = titleFont }
            for item in groupItems.values { item.titleFont = titleFont }
            needsLayout = true
        }
    }

    private let scrollView = NSScrollView()
    private let canvas = GroupedTabStripCanvas()
    private let newTabButton = NSButton(
        image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!,
        target: nil,
        action: #selector(TerminalController.newTab(_:)))
    private let leftButton = GroupedStripScrollButton(direction: .left)
    private let rightButton = GroupedStripScrollButton(direction: .right)

    private var tabItems: [UUID: GroupedTabItem] = [:]
    private var groupItems: [UUID: GroupedGroupHeaderItem] = [:]
    private var entries: [Entry] = []
    private var entryFrames: [NSRect] = []
    private var presentation: TabOrganization.Presentation?
    private var pendingPresentation: TabOrganization.Presentation?
    private var pendingReveal = false
    private var lastViewportWidth: CGFloat = 0
    private var press: Press?
    private var boundsObserver: NSObjectProtocol?

    fileprivate enum Entry {
        case group(GroupedGroupHeaderItem)
        case tab(GroupedTabItem, groupID: UUID?)
        case separator

        var view: GroupedStripItem? {
            switch self {
            case .group(let header): return header
            case .tab(let tab, _): return tab
            case .separator: return nil
            }
        }
    }

    fileprivate struct GroupBlock {
        let id: UUID
        let rect: NSRect
        let color: TerminalTabColor
        let collapsed: Bool
        let gaps: NSBezierPath?
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.viewportDidScroll()
        }

        leftButton.onPress = { [weak self] in self?.scrollByPage(direction: -1) }
        rightButton.onPress = { [weak self] in self?.scrollByPage(direction: 1) }
        leftButton.isHidden = true
        rightButton.isHidden = true
        newTabButton.isBordered = true
        newTabButton.bezelStyle = .circular
        newTabButton.controlSize = .small
        newTabButton.toolTip = "New Tab"
        newTabButton.setAccessibilityLabel("New Tab")

        addSubview(scrollView)
        addSubview(newTabButton)
        addSubview(leftButton)
        addSubview(rightButton)

        canvas.setAccessibilityRole(.tabGroup)
        canvas.setAccessibilityLabel("Tabs and groups")
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    // MARK: Rendering

    /// Reconciles the item views with the facade presentation. Views are kept per tab/group ID
    /// so hover, focus and drag state follow the same tab across renders.
    func render(_ presentation: TabOrganization.Presentation) {
        // A drop in progress owns the geometry; apply the new state once it settles.
        if press?.drag != nil {
            pendingPresentation = presentation
            return
        }

        let previousSelection = self.presentation?.selectedTabID
        let previousActive = self.presentation?.activeGroupID
        self.presentation = presentation

        var seenTabs = Set<UUID>()
        var seenGroups = Set<UUID>()
        var entries: [Entry] = []

        for group in presentation.groups {
            let header = groupItem(for: group.id)
            header.update(group)
            seenGroups.insert(group.id)
            entries.append(.group(header))

            // Only the active group exposes its members in the row.
            guard group.isActive else { continue }
            for tab in group.tabs {
                let item = tabItem(for: tab.id)
                item.update(tab, groupName: group.name)
                seenTabs.insert(tab.id)
                entries.append(.tab(item, groupID: group.id))
            }
        }

        if !presentation.unassigned.isEmpty {
            if !presentation.groups.isEmpty { entries.append(.separator) }
            for tab in presentation.unassigned {
                let item = tabItem(for: tab.id)
                item.update(tab, groupName: nil)
                seenTabs.insert(tab.id)
                entries.append(.tab(item, groupID: nil))
            }
        }

        for (id, item) in tabItems where !seenTabs.contains(id) {
            item.removeFromSuperview()
            tabItems[id] = nil
        }
        for (id, item) in groupItems where !seenGroups.contains(id) {
            item.removeFromSuperview()
            groupItems[id] = nil
        }

        self.entries = entries
        let views = entries.compactMap(\.view)
        canvas.subviews = views
        canvas.setAccessibilityTabs(views.compactMap { $0 as? GroupedTabItem })

        // Keyboard focus must not stay on a view that left the row.
        if let focused = window?.firstResponder as? GroupedStripItem, focused.superview == nil {
            delegate?.stripDidRequestTerminalFocus(self)
        }

        if presentation.selectedTabID != previousSelection || presentation.activeGroupID != previousActive {
            pendingReveal = true
        }
        needsLayout = true
    }

    private func tabItem(for id: UUID) -> GroupedTabItem {
        if let item = tabItems[id] { return item }
        let item = GroupedTabItem(strip: self, tabID: id)
        item.showsCloseButton = showsCloseButtons
        item.titleFont = titleFont
        tabItems[id] = item
        return item
    }

    private func groupItem(for id: UUID) -> GroupedGroupHeaderItem {
        if let item = groupItems[id] { return item }
        let item = GroupedGroupHeaderItem(strip: self, groupID: id)
        item.titleFont = titleFont
        groupItems[id] = item
        return item
    }

    private func applyPendingPresentation() {
        guard let pending = pendingPresentation else { return }
        pendingPresentation = nil
        render(pending)
    }

    // MARK: Layout

    private var rowBounds: NSRect { bounds }

    private var stripBounds: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY,
               width: max(0, bounds.width - Metrics.newTabButtonWidth - Metrics.newTabButtonGap),
               height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: stripBounds, xRadius: Self.rowHeight / 2, yRadius: Self.rowHeight / 2).fill()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        let bounds = self.bounds
        let row = rowBounds
        let scrollOrigin = scrollView.contentView.bounds.minX
        newTabButton.frame = NSRect(x: max(0, bounds.maxX - Metrics.newTabButtonWidth), y: row.minY,
                                    width: Metrics.newTabButtonWidth, height: row.height)
        scrollView.frame = stripBounds
        leftButton.frame = NSRect(x: scrollView.frame.minX, y: row.minY,
                                  width: Metrics.scrollButtonWidth, height: row.height)
        rightButton.frame = NSRect(x: max(scrollView.frame.minX, scrollView.frame.maxX - Metrics.scrollButtonWidth), y: row.minY,
                                   width: Metrics.scrollButtonWidth, height: row.height)

        layoutCanvas()
        scroll(toX: scrollOrigin)

        // A narrower viewport may push the selection out of sight; a plain refresh never
        // moves a manually scrolled strip.
        let viewport = scrollView.contentSize.width
        if viewport != lastViewportWidth {
            let hadViewport = lastViewportWidth > 0
            lastViewportWidth = viewport
            if hadViewport && !isSelectionVisible() { pendingReveal = true }
        }
        if pendingReveal {
            pendingReveal = false
            revealSelection()
        }

        updateScrollAffordances()
        canvas.syncHover()
    }

    /// Compact headers reserve their preferred widths; visible tabs equally fill the remainder.
    /// Headers compress before aggregate minima require scrolling.
    private func layoutCanvas() {
        var viewport = scrollView.contentSize.width
        guard viewport > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let inset = Int(ceil(Metrics.canvasInset * scale))

        var widths: [Int] = []
        widths.reserveCapacity(entries.count)
        var fixed = inset * 2
        var headerCapacity = 0
        var tabCount = 0
        var tabMinimumTotal = 0
        var widestTabMinimum = 0
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .group(let header):
                let width = Int(ceil(header.naturalWidth * scale))
                widths.append(width)
                headerCapacity += width - Int(ceil(header.minimumWidth * scale))
            case .tab(let tab, _):
                let width = Int(ceil(tab.minimumWidth * scale))
                widths.append(width)
                tabCount += 1
                tabMinimumTotal += width
                widestTabMinimum = max(widestTabMinimum, width)
            case .separator:
                widths.append(Int(ceil(Metrics.separatorWidth * scale)))
            }
            if index > 0 {
                fixed += Int(ceil(Self.spacing(between: entries[index - 1], and: entry) * scale))
            }
        }

        let preferredTotal = widths.reduce(0, +) + fixed
        let minimumTotal = preferredTotal - headerCapacity
        let overflows = minimumTotal > Int(floor(viewport * scale))
        if overflows {
            // Reserve both edge slots based on the full viewport, never on arrow visibility.
            scrollView.frame = scrollView.frame.insetBy(dx: Metrics.scrollButtonWidth, dy: 0)
            viewport = scrollView.contentSize.width
        }
        let viewportPixels = Int(floor(viewport * scale))
        let shrink = min(headerCapacity, max(0, preferredTotal - viewportPixels))
        if shrink > 0 {
            var remainingShrink = shrink
            var remainingCapacity = headerCapacity
            for (index, entry) in entries.enumerated() {
                guard case .group(let header) = entry else { continue }
                let capacity = widths[index] - Int(ceil(header.minimumWidth * scale))
                guard capacity > 0 else { continue }
                let reduction = remainingShrink * capacity / remainingCapacity
                widths[index] -= reduction
                remainingShrink -= reduction
                remainingCapacity -= capacity
            }
        }

        if !overflows && tabCount > 0 {
            var remainingPixels = viewportPixels - (preferredTotal - shrink - tabMinimumTotal)
            var remainingCount = tabCount
            var share = remainingPixels / remainingCount
            if widestTabMinimum > share {
                // Clamp the largest minima first; only the unconstrained tabs share what remains.
                var minimums: [Int] = []
                minimums.reserveCapacity(tabCount)
                for (entry, width) in zip(entries, widths) {
                    if case .tab = entry { minimums.append(width) }
                }
                minimums.sort(by: >)
                for minimum in minimums {
                    guard minimum > remainingPixels / remainingCount else { break }
                    remainingPixels -= minimum
                    remainingCount -= 1
                }
                share = remainingPixels / remainingCount
            }
            var remainder = remainingPixels % remainingCount
            for (index, entry) in entries.enumerated() {
                guard case .tab = entry, widths[index] <= share else { continue }
                widths[index] = share
                if remainder > 0 {
                    widths[index] += 1
                    remainder -= 1
                }
            }
        }

        var frames: [NSRect] = []
        frames.reserveCapacity(entries.count)
        var separatorFrame: NSRect?
        var x = inset
        let y = rowBounds.minY + (Self.rowHeight - Metrics.itemHeight) / 2
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                x += Int(ceil(Self.spacing(between: entries[index - 1], and: entry) * scale))
            }
            let frame = NSRect(x: CGFloat(x) / scale, y: y,
                               width: CGFloat(widths[index]) / scale, height: Metrics.itemHeight)
            frames.append(frame)
            if case .separator = entry { separatorFrame = frame }
            x += widths[index]
        }
        entryFrames = frames

        let contentWidth = CGFloat(x + inset) / scale
        canvas.frame = NSRect(x: 0, y: 0, width: max(contentWidth, viewport), height: bounds.height)
        for (entry, frame) in zip(entries, frames) {
            entry.view?.frame = frame
        }

        canvas.groupBlocks = groupBlocks()
        canvas.separatorFrame = separatorFrame
        canvas.selectedItem = selectedItem()
        canvas.needsDisplay = true

        // Content that shrank while scrolled must not leave the viewport past its end.
        let clip = scrollView.contentView
        let maxOrigin = max(0, canvas.frame.width - clip.bounds.width)
        if clip.bounds.origin.x > maxOrigin {
            clip.scroll(to: NSPoint(x: maxOrigin, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private static func spacing(between previous: Entry, and next: Entry) -> CGFloat {
        switch (previous, next) {
        case (.group(let header), .tab(_, let groupID)) where header.groupID == groupID:
            return Metrics.memberSpacing
        case (.tab(_, let lhs), .tab(_, let rhs)) where lhs == rhs:
            return lhs == nil ? Metrics.tabSpacing : Metrics.memberSpacing
        case (.separator, _), (_, .separator):
            return Metrics.sectionGap / 2 + 2
        default:
            return Metrics.sectionGap
        }
    }

    /// Header-through-last-member rectangles per group in row order.
    private func groupBlocks() -> [GroupBlock] {
        var blocks: [GroupBlock] = []
        var currentHeader: GroupedGroupHeaderItem?
        var currentRect = NSRect.zero
        var previousFrame = NSRect.zero
        var gaps: NSBezierPath?
        func flush() {
            if let header = currentHeader {
                blocks.append(GroupBlock(id: header.groupID, rect: currentRect, color: header.color,
                                         collapsed: !header.isActive, gaps: gaps))
            }
            currentHeader = nil
            gaps = nil
        }
        for (entry, frame) in zip(entries, entryFrames) {
            switch entry {
            case .group(let header):
                flush()
                currentHeader = header
                currentRect = frame
                previousFrame = frame
                if header.color != .none && header.isActive { gaps = NSBezierPath() }
            case .tab(_, let groupID):
                if let header = currentHeader, header.groupID == groupID {
                    if let gaps {
                        gaps.append(Self.gapOutline(between: previousFrame, and: frame))
                    }
                    previousFrame = frame
                    currentRect = currentRect.union(frame)
                } else {
                    flush()
                }
            case .separator:
                flush()
            }
        }
        flush()
        return blocks
    }

    /// The internal gap follows both item faces without painting underneath either one.
    private static func gapOutline(between left: NSRect, and right: NSRect) -> NSBezierPath {
        let radius = Metrics.cornerRadius
        let arc: CGFloat = 0.5522847498
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left.maxX - radius, y: left.maxY))
        path.line(to: NSPoint(x: right.minX + radius, y: right.maxY))
        path.curve(to: NSPoint(x: right.minX, y: right.maxY - radius),
                   controlPoint1: NSPoint(x: right.minX + radius * (1 - arc), y: right.maxY),
                   controlPoint2: NSPoint(x: right.minX, y: right.maxY - radius * (1 - arc)))
        path.line(to: NSPoint(x: right.minX, y: right.minY + radius))
        path.curve(to: NSPoint(x: right.minX + radius, y: right.minY),
                   controlPoint1: NSPoint(x: right.minX, y: right.minY + radius * (1 - arc)),
                   controlPoint2: NSPoint(x: right.minX + radius * (1 - arc), y: right.minY))
        path.line(to: NSPoint(x: left.maxX - radius, y: left.minY))
        path.curve(to: NSPoint(x: left.maxX, y: left.minY + radius),
                   controlPoint1: NSPoint(x: left.maxX - radius * (1 - arc), y: left.minY),
                   controlPoint2: NSPoint(x: left.maxX, y: left.minY + radius * (1 - arc)))
        path.line(to: NSPoint(x: left.maxX, y: left.maxY - radius))
        path.curve(to: NSPoint(x: left.maxX - radius, y: left.maxY),
                   controlPoint1: NSPoint(x: left.maxX, y: left.maxY - radius * (1 - arc)),
                   controlPoint2: NSPoint(x: left.maxX - radius * (1 - arc), y: left.maxY))
        path.close()
        return path
    }

    // MARK: Scrolling

    fileprivate func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard window === event.window, !isHiddenOrHasHiddenAncestor else { return false }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        // With unclipped AppKit ancestors, visibleRect can extend over the terminal content.
        guard scrollView.bounds.contains(point), scrollView.visibleRect.contains(point) else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    private func viewportDidScroll() {
        updateScrollAffordances()
        canvas.syncHover()
    }

    private func updateScrollAffordances() {
        let clip = scrollView.contentView.bounds
        let overflow = canvas.frame.width > clip.width + 0.5
        leftButton.isHidden = !overflow || clip.minX <= 0.5
        rightButton.isHidden = !overflow || clip.maxX >= canvas.frame.width - 0.5
    }

    private func scrollByPage(direction: CGFloat) {
        let clip = scrollView.contentView
        let page = max(40, clip.bounds.width - 40)
        scroll(toX: clip.bounds.origin.x + direction * page)
    }

    private func scroll(toX x: CGFloat) {
        let clip = scrollView.contentView
        let clamped = max(0, min(x, canvas.frame.width - clip.bounds.width))
        guard clamped != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: clamped, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func canScroll(direction: CGFloat) -> Bool {
        let clip = scrollView.contentView.bounds
        return direction < 0 ? clip.minX > 0.5 : clip.maxX < canvas.frame.width - 0.5
    }

    private func selectedItem() -> GroupedTabItem? {
        guard let id = presentation?.selectedTabID, let item = tabItems[id], item.superview === canvas else { return nil }
        return item
    }

    private func isSelectionVisible() -> Bool {
        guard let item = selectedItem() else { return true }
        return scrollView.contentView.bounds.contains(item.frame)
    }

    /// Reveals the selected tab, together with its group header when both fit the viewport.
    private func revealSelection() {
        guard let item = selectedItem() else { return }
        var target = item.frame
        if let memberGroupID = groupID(ofTab: item.tabID), let header = groupItems[memberGroupID],
           header.superview === canvas {
            let union = header.frame.union(item.frame)
            if union.width <= scrollView.contentView.bounds.width { target = union }
        }
        reveal(target)
    }

    private func reveal(_ rect: NSRect) {
        let visible = scrollView.contentView.bounds
        var x = visible.origin.x
        if rect.minX - Metrics.revealMargin < visible.minX {
            x = rect.minX - Metrics.revealMargin
        } else if rect.maxX + Metrics.revealMargin > visible.maxX {
            x = rect.maxX + Metrics.revealMargin - visible.width
        }
        scroll(toX: x)
    }

    private func groupID(ofTab id: UUID) -> UUID? {
        for entry in entries {
            if case .tab(let item, let groupID) = entry, item.tabID == id { return groupID }
        }
        return nil
    }

    private var orderedItems: [GroupedStripItem] {
        entries.compactMap(\.view)
    }

    // MARK: Actions

    fileprivate func request(_ action: TabOrganization.Action) {
        delegate?.strip(self, perform: action)
    }

    /// Hit-tests an event against the strip's items; the close button resolves to its tab.
    fileprivate func item(at event: NSEvent) -> GroupedStripItem? {
        guard let window, event.window === window, let superview else { return nil }
        let point = superview.convert(event.locationInWindow, from: nil)
        var view = hitTest(point)
        while let current = view {
            if let item = current as? GroupedStripItem { return item }
            view = current.superview
        }
        return nil
    }

    fileprivate func contextMenu(for item: GroupedStripItem) -> NSMenu? {
        if let tab = item as? GroupedTabItem {
            return delegate?.strip(self, contextMenuForTab: tab.tabID)
        }
        if let header = item as? GroupedGroupHeaderItem {
            return delegate?.strip(self, contextMenuForGroup: header.groupID)
        }
        return nil
    }

    /// Opens the item's menu at the pointer for a mouse event, or below the item for keyboard and
    /// accessibility requests. Items target the clicked tab, never the selected one.
    fileprivate func showContextMenu(for item: GroupedStripItem, with event: NSEvent?) {
        guard item.superview != nil, let menu = contextMenu(for: item) else { return }
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: item)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: item)
        }
    }

    // MARK: Keyboard

    /// Handles a key press on a focused item. Returns false when the key is not part of the row's
    /// vocabulary so the usual responder behavior applies.
    fileprivate func handleKeyDown(_ event: NSEvent, on item: GroupedStripItem) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .option]) else { return false }
        switch event.keyCode {
        case 49, 36, 76: // space, return, keypad enter
            if flags.contains(.control) {
                showContextMenu(for: item, with: nil)
            } else {
                item.performPrimaryAction()
            }
            return true
        case 123: // left arrow
            focusNeighbor(of: item, offset: -1, leavesRow: false)
            return true
        case 124: // right arrow
            focusNeighbor(of: item, offset: 1, leavesRow: false)
            return true
        case 48: // tab
            focusNeighbor(of: item, offset: flags.contains(.shift) ? -1 : 1, leavesRow: true)
            return true
        case 53: // escape
            delegate?.stripDidRequestTerminalFocus(self)
            return true
        case 51, 117: // delete, forward delete
            guard let header = item as? GroupedGroupHeaderItem else { return false }
            request(.deleteGroup(header.groupID))
            return true
        case 109 where flags.contains(.shift): // shift-F10
            showContextMenu(for: item, with: nil)
            return true
        default:
            return false
        }
    }

    private func focusNeighbor(of item: GroupedStripItem, offset: Int, leavesRow: Bool) {
        let items = orderedItems
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else {
            if leavesRow { delegate?.stripDidRequestTerminalFocus(self) }
            return
        }
        focus(items[target])
    }

    private func focus(_ item: GroupedStripItem) {
        window?.makeFirstResponder(item)
        reveal(item.frame)
    }

    override var acceptsFirstResponder: Bool {
        !entries.isEmpty
    }

    /// The toolbar hands keyboard focus to the item view; it continues to the selected tab so
    /// arrow keys start from the selection.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            let selected: GroupedStripItem? = self.selectedItem()
            if let item = selected ?? self.orderedItems.first {
                self.focus(item)
            }
        }
        return true
    }

    // MARK: Press and Drag Tracking

    private final class Press {
        let item: GroupedStripItem
        let start: NSPoint
        var drag: DragSession?

        init(item: GroupedStripItem, start: NSPoint) {
            self.item = item
            self.start = start
        }
    }

    private final class DragSession {
        enum Kind {
            case tab(id: UUID, sourceGroupID: UUID?, sourceIndex: Int)
            case group(id: UUID, sourceIndex: Int)
        }

        let kind: Kind
        let ghost: NSImageView
        let grabOffsetX: CGFloat
        let draggedItems: [GroupedStripItem]
        var lastLocation: NSPoint
        var target: DropTarget?
        var isOutside = false
        var autoScrollDirection: CGFloat = 0
        var autoScrollTimer: Timer?
        var keyMonitor: Any?

        init(kind: Kind, ghost: NSImageView, grabOffsetX: CGFloat, draggedItems: [GroupedStripItem], location: NSPoint) {
            self.kind = kind
            self.ghost = ghost
            self.grabOffsetX = grabOffsetX
            self.draggedItems = draggedItems
            self.lastLocation = location
        }
    }

    private enum DropTarget: Equatable {
        /// Insert into the partition (`nil` = unassigned) at the final index.
        case tab(groupID: UUID?, index: Int, indicatorX: CGFloat)
        /// Append to the group, including a collapsed one.
        case groupHeader(UUID)
        /// Move the whole group block to the final named-group index.
        case group(index: Int, indicatorX: CGFloat)
    }

    fileprivate func beginPress(on item: GroupedStripItem, with event: NSEvent) {
        cancelDrag()
        press = Press(item: item, start: convert(event.locationInWindow, from: nil))
        item.isPressed = true
    }

    fileprivate func continuePress(with event: NSEvent) {
        guard let press else { return }
        let location = convert(event.locationInWindow, from: nil)
        if press.drag == nil {
            guard abs(location.x - press.start.x) >= Metrics.dragThreshold ||
                  abs(location.y - press.start.y) >= Metrics.dragThreshold else { return }
            guard let session = startDrag(for: press.item, at: location) else { return }
            press.drag = session
            press.item.isPressed = false
        }
        updateDrag(at: location)
    }

    fileprivate func endPress(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        press.item.isPressed = false

        if let drag = press.drag {
            finishDrag(drag)
            return
        }

        // A plain click acts on release inside the item, like a button. Focus follows the
        // selection through the facade's activation path, never through the header.
        guard press.item.superview != nil,
              press.item.bounds.contains(press.item.convert(event.locationInWindow, from: nil)) else { return }
        if let header = press.item as? GroupedGroupHeaderItem, event.clickCount >= 2 {
            request(.renameGroup(header.groupID))
            return
        }
        press.item.performPrimaryAction()
    }

    private func startDrag(for item: GroupedStripItem, at location: NSPoint) -> DragSession? {
        guard let presentation else { return nil }
        let kind: DragSession.Kind
        let items: [GroupedStripItem]
        if let tab = item as? GroupedTabItem {
            guard let position = position(ofTab: tab.tabID) else { return nil }
            kind = .tab(id: tab.tabID, sourceGroupID: position.groupID, sourceIndex: position.index)
            items = [tab]
        } else if let header = item as? GroupedGroupHeaderItem {
            guard let index = presentation.groups.firstIndex(where: { $0.id == header.groupID }) else { return nil }
            kind = .group(id: header.groupID, sourceIndex: index)
            items = [header as GroupedStripItem] + memberItems(of: header.groupID)
        } else {
            return nil
        }

        var rect = items[0].frame
        for view in items.dropFirst() { rect = rect.union(view.frame) }
        guard let image = canvas.snapshot(of: rect, clipToItem: item is GroupedTabItem) else { return nil }
        let ghost = NSImageView(image: image)
        ghost.imageScaling = .scaleNone
        ghost.wantsLayer = true
        ghost.alphaValue = 0.85
        ghost.frame = convert(rect, from: canvas)
        addSubview(ghost)
        for view in items { view.isDragSource = true }

        let session = DragSession(kind: kind, ghost: ghost, grabOffsetX: location.x - ghost.frame.minX,
                                  draggedItems: items, location: location)
        // Escape cancels; every other key keeps its normal routing.
        session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.press?.drag != nil, event.keyCode == 53 else { return event }
            self.cancelDrag()
            return nil
        }
        return session
    }

    private func updateDrag(at location: NSPoint) {
        guard let drag = press?.drag else { return }
        drag.lastLocation = location
        drag.ghost.frame.origin.x = location.x - drag.grabOffsetX

        // Group blocks clamp horizontally; single tabs can tear off past either row edge.
        var isOutside = location.y < rowBounds.minY - Metrics.detachDistance ||
            location.y > rowBounds.maxY + Metrics.detachDistance
        if case .tab = drag.kind {
            isOutside = isOutside || location.x < bounds.minX - Metrics.detachDistance ||
                location.x > bounds.maxX + Metrics.detachDistance
        }
        drag.isOutside = isOutside
        if isOutside {
            drag.target = nil
            drag.ghost.alphaValue = 0.35
            applyIndicator(nil)
            stopAutoScroll(drag)
            return
        }

        drag.ghost.alphaValue = 0.85
        let canvasX = canvas.convert(location, from: self).x
        let target: DropTarget?
        switch drag.kind {
        case .tab(let id, let sourceGroupID, let sourceIndex):
            target = tabDropTarget(id: id, sourceGroupID: sourceGroupID, sourceIndex: sourceIndex, canvasX: canvasX)
        case .group(let id, let sourceIndex):
            target = groupDropTarget(id: id, sourceIndex: sourceIndex, canvasX: canvasX)
        }
        drag.target = target
        applyIndicator(target)
        autoScrollIfNeeded(drag, at: location)
    }

    private func applyIndicator(_ target: DropTarget?) {
        var highlighted: UUID?
        var indicatorX: CGFloat?
        switch target {
        case .some(.tab(_, _, let x)), .some(.group(_, let x)):
            indicatorX = x
        case .some(.groupHeader(let groupID)):
            highlighted = groupID
        case .none:
            break
        }
        canvas.dropIndicatorX = indicatorX
        for (id, header) in groupItems {
            header.isDropTarget = id == highlighted
        }
    }

    private func finishDrag(_ drag: DragSession) {
        // An index describes the layout shown during the drag, not a later partition.
        // Cancel after native membership/order/activation changes rather than commit a stale slot.
        pendingPresentation = delegate?.stripPresentationForDrop(self)
        let structureChanged: Bool
        if let pending = pendingPresentation, let current = presentation {
            structureChanged = pending.windowID != current.windowID ||
                pending.activeGroupID != current.activeGroupID ||
                pending.unassigned.map(\.id) != current.unassigned.map(\.id) ||
                pending.groups.count != current.groups.count ||
                zip(pending.groups, current.groups).contains {
                    $0.0.id != $0.1.id || $0.0.tabs.map(\.id) != $0.1.tabs.map(\.id)
                }
        } else {
            structureChanged = true
        }
        teardown(drag)
        // State deferred during the drag is applied first so a synchronous facade change from the
        // move below is never overwritten by an older presentation.
        applyPendingPresentation()
        guard !structureChanged else {
            delegate?.stripDidRequestTerminalFocus(self)
            return
        }

        if drag.isOutside {
            // Only single tabs tear off, through the existing native operation.
            if case .tab(let id, _, _) = drag.kind {
                request(.detachTab(id, screenPoint: NSEvent.mouseLocation))
            }
            return
        }
        // AppKit can focus a keyboard-accessible item on mouse-down. An internal
        // drop must return typing to the still-selected native terminal.
        defer { delegate?.stripDidRequestTerminalFocus(self) }

        guard let target = drag.target else { return }
        switch (drag.kind, target) {
        case (.tab(let id, _, _), .groupHeader(let groupID)):
            request(.moveTab(tabID: id, groupID: groupID, index: nil))
        case (.tab(let id, _, _), .tab(let groupID, let index, _)):
            request(.moveTab(tabID: id, groupID: groupID, index: index))
        case (.group(let id, _), .group(let index, _)):
            request(.moveGroup(groupID: id, index: index))
        default:
            break
        }
    }

    private func cancelDrag() {
        guard let press, let drag = press.drag else { return }
        self.press = nil
        press.item.isPressed = false
        teardown(drag)
        applyPendingPresentation()
        delegate?.stripDidRequestTerminalFocus(self)
    }

    private func teardown(_ drag: DragSession) {
        stopAutoScroll(drag)
        if let monitor = drag.keyMonitor {
            NSEvent.removeMonitor(monitor)
            drag.keyMonitor = nil
        }
        drag.ghost.removeFromSuperview()
        for view in drag.draggedItems { view.isDragSource = false }
        applyIndicator(nil)
    }

    private func autoScrollIfNeeded(_ drag: DragSession, at location: NSPoint) {
        let frame = scrollView.frame
        let direction: CGFloat
        if location.x < frame.minX + Metrics.autoScrollMargin {
            direction = -1
        } else if location.x > frame.maxX - Metrics.autoScrollMargin {
            direction = 1
        } else {
            stopAutoScroll(drag)
            return
        }
        guard canScroll(direction: direction) else {
            stopAutoScroll(drag)
            return
        }
        drag.autoScrollDirection = direction
        guard drag.autoScrollTimer == nil else { return }
        drag.autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
    }

    private func stopAutoScroll(_ drag: DragSession) {
        drag.autoScrollTimer?.invalidate()
        drag.autoScrollTimer = nil
        drag.autoScrollDirection = 0
    }

    private func autoScrollTick() {
        guard let drag = press?.drag, drag.autoScrollDirection != 0 else { return }
        let clip = scrollView.contentView
        scroll(toX: clip.bounds.origin.x + drag.autoScrollDirection * Metrics.autoScrollStep)
        // Items moved under the pointer; the target follows the new geometry, and the scroll stops
        // by itself at either end.
        updateDrag(at: drag.lastLocation)
    }

    // MARK: Drop Targets

    private func position(ofTab id: UUID) -> (groupID: UUID?, index: Int)? {
        guard let presentation else { return nil }
        for group in presentation.groups {
            if let index = group.tabs.firstIndex(where: { $0.id == id }) { return (group.id, index) }
        }
        if let index = presentation.unassigned.firstIndex(where: { $0.id == id }) { return (nil, index) }
        return nil
    }

    private func memberItems(of groupID: UUID) -> [GroupedStripItem] {
        var items: [GroupedStripItem] = []
        for entry in entries {
            if case .tab(let item, let id) = entry, id == groupID { items.append(item) }
        }
        return items
    }

    private func tabDropTarget(id: UUID, sourceGroupID: UUID?, sourceIndex: Int, canvasX: CGFloat) -> DropTarget? {
        guard let presentation, !entries.isEmpty, entryFrames.count == entries.count,
              let first = entryFrames.first, let last = entryFrames.last else { return nil }

        // Past the trailing edge is the unassigned region even when it currently has no tabs.
        if canvasX > last.maxX + Metrics.sectionGap / 2 {
            return insertion(groupID: nil, visibleIndex: presentation.unassigned.count,
                             sourceGroupID: sourceGroupID, sourceIndex: sourceIndex,
                             indicatorX: last.maxX + Metrics.sectionGap / 2)
        }
        if canvasX < first.minX - Metrics.sectionGap / 2 {
            if case .group(let header) = entries[0] {
                return headerTarget(header, sourceGroupID: sourceGroupID, sourceIndex: sourceIndex)
            }
            return insertion(groupID: nil, visibleIndex: 0, sourceGroupID: sourceGroupID, sourceIndex: sourceIndex,
                             indicatorX: first.minX - 2)
        }

        // The entry under the pointer, or the nearest one when the pointer is in a gap.
        var chosen = entryFrames.firstIndex { canvasX >= $0.minX && canvasX <= $0.maxX }
        if chosen == nil {
            var bestIndex = 0
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, frame) in entryFrames.enumerated() {
                let distance = canvasX < frame.minX ? frame.minX - canvasX : canvasX - frame.maxX
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            chosen = bestIndex
        }
        guard let index = chosen else { return nil }
        let frame = entryFrames[index]

        switch entries[index] {
        case .group(let header):
            return headerTarget(header, sourceGroupID: sourceGroupID, sourceIndex: sourceIndex)
        case .separator:
            return insertion(groupID: nil, visibleIndex: 0, sourceGroupID: sourceGroupID, sourceIndex: sourceIndex,
                             indicatorX: frame.maxX + Metrics.sectionGap / 2)
        case .tab(_, let groupID):
            let before = canvasX < frame.midX
            var visibleIndex = 0
            for entry in entries[..<index] {
                if case .tab(_, let other) = entry, other == groupID { visibleIndex += 1 }
            }
            if !before { visibleIndex += 1 }
            return insertion(groupID: groupID, visibleIndex: visibleIndex, sourceGroupID: sourceGroupID,
                             sourceIndex: sourceIndex, indicatorX: before ? frame.minX - 2 : frame.maxX + 2)
        }
    }

    /// Appending to the group the tab already ends is a no-op; every other header drop appends.
    private func headerTarget(_ header: GroupedGroupHeaderItem, sourceGroupID: UUID?, sourceIndex: Int) -> DropTarget? {
        if sourceGroupID == header.groupID,
           let count = presentation?.groups.first(where: { $0.id == header.groupID })?.tabs.count,
           sourceIndex == count - 1 {
            return nil
        }
        return .groupHeader(header.groupID)
    }

    /// Converts a slot among the visible members into the final index after the dragged tab has
    /// left its source position; returns nil when nothing would change.
    private func insertion(groupID: UUID?, visibleIndex: Int, sourceGroupID: UUID?, sourceIndex: Int,
                           indicatorX: CGFloat) -> DropTarget? {
        var finalIndex = visibleIndex
        if groupID == sourceGroupID {
            if sourceIndex < visibleIndex { finalIndex -= 1 }
            if finalIndex == sourceIndex { return nil }
        }
        return .tab(groupID: groupID, index: finalIndex, indicatorX: indicatorX)
    }

    /// Group blocks reorder among themselves; anything past the last block, including the
    /// unassigned tabs, clamps to the final named-group position.
    private func groupDropTarget(id: UUID, sourceIndex: Int, canvasX: CGFloat) -> DropTarget? {
        guard let groupCount = presentation?.groups.count, groupCount > 1 else { return nil }
        let others = canvas.groupBlocks.filter { $0.id != id }
        var index = 0
        for block in others where canvasX > block.rect.midX { index += 1 }
        index = min(index, groupCount - 1)
        guard index != sourceIndex else { return nil }
        let indicatorX: CGFloat
        if index < others.count {
            indicatorX = others[index].rect.minX - Metrics.sectionGap / 2
        } else if let lastBlock = others.last {
            indicatorX = lastBlock.rect.maxX + Metrics.sectionGap / 2
        } else {
            return nil
        }
        return .group(index: index, indicatorX: indicatorX)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        cancelDrag()
    }
}

// MARK: - Canvas

/// Rounded item feedback, group accents and drop indicators within the scrolling viewport.
private final class GroupedTabStripCanvas: NSView {
    weak var terminalWindow: TerminalWindow?
    var groupBlocks: [GroupedTabStrip.GroupBlock] = []
    var separatorFrame: NSRect? { didSet { needsDisplay = true } }
    var dropIndicatorX: CGFloat? { didSet { needsDisplay = true } }
    weak var selectedItem: GroupedTabItem? { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        for block in groupBlocks {
            guard let color = block.color.displayColor else { continue }
            if block.collapsed {
                color.setStroke()
                let outline = NSBezierPath(roundedRect: block.rect.insetBy(dx: 0.75, dy: 0.75),
                                           xRadius: GroupedTabStrip.Metrics.cornerRadius - 0.75,
                                           yRadius: GroupedTabStrip.Metrics.cornerRadius - 0.75)
                outline.lineWidth = 1.5
                outline.stroke()
            } else {
                color.setFill()
                block.gaps?.fill()
            }
        }
        let selection = selectedItem.flatMap { item -> NSBezierPath? in
            guard item.superview === self, item.isSelected else { return nil }
            return selectionOutline(for: item.frame)
        }
        let hoveredItem = subviews.first {
            guard let item = $0 as? GroupedTabItem else { return false }
            return !item.isSelected && (item.isHovered || item.isPressed)
        } as? GroupedTabItem
        let hover = hoveredItem.map { selectionOutline(for: $0.frame) }

        if let hover {
            NSColor.labelColor.withAlphaComponent(hoveredItem?.isPressed == true ? 0.10 : 0.05).setFill()
            hover.fill()
            let emphasis: CGFloat = hoveredItem?.isDragSource == true ? 0.3 : 1
            NSColor.labelColor.withAlphaComponent((hoveredItem?.isPressed == true ? 0.16 : 0.1) * emphasis).setStroke()
            hover.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
            hover.stroke()
        }

        if let selection {
            let isDark = effectiveAppearance.isDark
            let isMain = terminalWindow?.isMainWindow == true
            let opacity: CGFloat = isDark ? (isMain ? 0.14 : 0.08) : (isMain ? 0.85 : 0.45)
            NSColor.white.withAlphaComponent(opacity).setFill()
            selection.fill()
            let emphasis: CGFloat = selectedItem?.isDragSource == true ? 0.3 : 1
            NSColor.labelColor.withAlphaComponent((isDark ? 0.24 : 0.1) * emphasis).setStroke()
            selection.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
            selection.stroke()
        }

        if let separatorFrame {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: separatorFrame.midX - 0.5, y: separatorFrame.minY + 2,
                   width: 1, height: separatorFrame.height - 4).fill()
        }

        for case let header as GroupedGroupHeaderItem in subviews where header.isDropTarget {
            let rect = header.frame
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            let inset: CGFloat = 3.25
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                      xRadius: GroupedTabStrip.Metrics.cornerRadius - inset,
                                      yRadius: GroupedTabStrip.Metrics.cornerRadius - inset)
            border.lineWidth = 1.5
            border.stroke()
        }

        if let dropIndicatorX {
            NSColor.controlAccentColor.setFill()
            let rowBottom = bounds.maxY - GroupedTabStrip.rowHeight
            var rect = NSRect(x: dropIndicatorX - 1,
                              y: rowBottom + (GroupedTabStrip.rowHeight - GroupedTabStrip.Metrics.itemHeight) / 2,
                              width: 2, height: GroupedTabStrip.Metrics.itemHeight)
            // Clamp to the document, not the viewport: offscreen slots must stay offscreen.
            rect.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func selectionOutline(for frame: NSRect) -> NSBezierPath {
        let inset = 0.5 / (window?.backingScaleFactor ?? 2)
        return NSBezierPath(roundedRect: frame.insetBy(dx: inset, dy: inset),
                            xRadius: GroupedTabStrip.Metrics.cornerRadius - inset,
                            yRadius: GroupedTabStrip.Metrics.cornerRadius - inset)
    }

    /// Scrolling moves items under a stationary pointer without tracking-area callbacks.
    func syncHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        for case let item as GroupedStripItem in subviews {
            item.isHovered = item.frame.contains(point) && visibleRect.contains(point)
        }
    }

    func snapshot(of rect: NSRect, clipToItem: Bool) -> NSImage? {
        guard rect.width > 0, rect.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: representation)
        if clipToItem, let context = NSGraphicsContext(bitmapImageRep: representation)?.cgContext {
            let bounds = NSRect(origin: .zero, size: rect.size)
            context.scaleBy(x: CGFloat(representation.pixelsWide) / rect.width,
                            y: CGFloat(representation.pixelsHigh) / rect.height)
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addRoundedRect(in: bounds, cornerWidth: GroupedTabStrip.Metrics.cornerRadius,
                                   cornerHeight: GroupedTabStrip.Metrics.cornerRadius)
            context.addPath(outside)
            context.clip(using: .evenOdd)
            context.clear(bounds)
        }
        let image = NSImage(size: rect.size)
        image.addRepresentation(representation)
        return image
    }
}

// MARK: - Items

/// Shared behavior of tabs and group headers: hover and pressed feedback, keyboard focus, context
/// menus, accessibility actions, and press forwarding to the strip's tracking.
private class GroupedStripItem: NSView {
    weak var strip: GroupedTabStrip?
    let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var isHovered = false {
        didSet {
            if isHovered != oldValue {
                needsDisplay = true
                superview?.needsDisplay = true
            }
        }
    }
    var isPressed = false {
        didSet {
            if isPressed != oldValue {
                needsDisplay = true
                superview?.needsDisplay = true
            }
        }
    }
    var isDropTarget = false {
        didSet {
            if isDropTarget != oldValue {
                superview?.needsDisplay = true
            }
        }
    }
    var isDragSource = false {
        didSet {
            alphaValue = isDragSource ? 0.3 : 1
            superview?.needsDisplay = true
        }
    }

    init(strip: GroupedTabStrip) {
        self.strip = strip
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: GroupedTabStrip.Metrics.itemHeight))
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Subclass surface.
    var minimumWidth: CGFloat { 0 }
    var itemTitle: String { "" }
    func performPrimaryAction() {}

    var naturalLabelWidth: CGFloat {
        // The cell includes text insets that attributed-string measurement omits.
        label.cell?.cellSize.width ?? label.intrinsicContentSize.width
    }

    // MARK: NSView

    override var mouseDownCanMoveWindow: Bool { false }
    // Pointer selection returns focus to the terminal; only keyboard navigation focuses this item.
    override var acceptsFirstResponder: Bool { NSApp.currentEvent?.type != .leftMouseDown }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        noteFocusRingMaskChanged()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: GroupedTabStrip.Metrics.cornerRadius,
                     yRadius: GroupedTabStrip.Metrics.cornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    /// The whole item is one target; labels never take mouse events, buttons keep theirs.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for subview in subviews where subview is NSButton && !subview.isHidden {
            if subview.frame.contains(local) { return subview }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { strip?.beginPress(on: self, with: event) }
    override func mouseDragged(with event: NSEvent) { strip?.continuePress(with: event) }
    override func mouseUp(with event: NSEvent) { strip?.endPress(with: event) }
    override func rightMouseDown(with event: NSEvent) { strip?.showContextMenu(for: self, with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { strip?.contextMenu(for: self) }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        if strip?.handleKeyDown(event, on: self) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { strip?.delegate != nil }
    override func accessibilityLabel() -> String? { itemTitle }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        strip?.showContextMenu(for: self, with: nil)
        return true
    }
}

/// One terminal tab: optional tab color dot, tail-truncated title and an optional close button.
private final class GroupedTabItem: GroupedStripItem {
    private typealias Metrics = GroupedTabStrip.Metrics
    private static let font = NSFont.systemFont(ofSize: 12)

    let tabID: UUID
    private(set) var title = ""
    private(set) var color: TerminalTabColor = .none
    private(set) var isSelected = false
    private(set) var groupName: String?
    private var labelWidth: CGFloat = 0
    private let closeButton: NSButton

    var titleFont: NSFont? {
        didSet {
            label.font = titleFont ?? Self.font
            labelWidth = naturalLabelWidth
            needsLayout = true
        }
    }

    var showsCloseButton = true {
        didSet {
            closeButton.isHidden = !showsCloseButton
            needsLayout = true
        }
    }

    init(strip: GroupedTabStrip, tabID: UUID) {
        self.tabID = tabID
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        image?.isTemplate = true
        closeButton = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        super.init(strip: strip)

        label.font = Self.font
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Tab"
        closeButton.setButtonType(.momentaryChange)
        // Keyboard users close through the context menu; the button never captures focus.
        closeButton.refusesFirstResponder = true
        addSubview(closeButton)

        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.tabButtonSubrole)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ tab: TabOrganization.TabPresentation, groupName: String?) {
        if tab.title != title || label.stringValue != tab.title {
            title = tab.title
            label.stringValue = title
            labelWidth = naturalLabelWidth
            toolTip = title
            closeButton.setAccessibilityLabel("Close \(title)")
        }
        color = tab.color
        isSelected = tab.isSelected
        self.groupName = groupName
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        needsLayout = true
        needsDisplay = true
    }

    @objc private func closeTab(_ sender: Any?) {
        strip?.request(.closeTab(tabID))
    }

    override func performPrimaryAction() {
        strip?.request(.activateTab(tabID))
    }

    // MARK: Layout

    private var chromeWidth: CGFloat {
        var width = Metrics.horizontalPadding * 2
        if color != .none { width += Metrics.colorDotSize + Metrics.iconSpacing }
        if showsCloseButton { width += Metrics.iconSpacing + Metrics.closeButtonSize }
        return width
    }

    override var minimumWidth: CGFloat { chromeWidth + min(labelWidth, Metrics.tabMinLabelWidth) }

    override func layout() {
        super.layout()
        var x = Metrics.horizontalPadding
        if color != .none { x += Metrics.colorDotSize + Metrics.iconSpacing }
        var labelRight = bounds.maxX - Metrics.horizontalPadding
        if showsCloseButton {
            closeButton.frame = NSRect(x: labelRight - Metrics.closeButtonSize,
                                       y: (bounds.height - Metrics.closeButtonSize) / 2,
                                       width: Metrics.closeButtonSize, height: Metrics.closeButtonSize)
            labelRight -= Metrics.closeButtonSize + Metrics.iconSpacing
        }
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: floor((bounds.height - height) / 2), width: max(0, labelRight - x), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The canvas draws connected selection, hover and press feedback behind this hit target.

        if let dot = color.displayColor {
            let rect = NSRect(x: Metrics.horizontalPadding, y: (bounds.height - Metrics.colorDotSize) / 2,
                              width: Metrics.colorDotSize, height: Metrics.colorDotSize)
            dot.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    // MARK: Accessibility

    override var itemTitle: String { title }
    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    override func isAccessibilitySelected() -> Bool { isSelected }

    override func accessibilityHelp() -> String? {
        if let groupName { return "Tab in group \(groupName)" }
        return "Ungrouped tab"
    }
}

/// One named group: disclosure chevron and tail-truncated name. Expanded when the group is the
/// window's active group; accepts tab drops even while collapsed.
private final class GroupedGroupHeaderItem: GroupedStripItem {
    private typealias Metrics = GroupedTabStrip.Metrics
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    let groupID: UUID
    private(set) var name = ""
    private(set) var isActive = false
    private(set) var memberCount = 0
    private(set) var color: TerminalTabColor = .none
    private var labelWidth: CGFloat = 0

    var titleFont: NSFont? {
        didSet {
            label.font = titleFont.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? Self.font
            labelWidth = naturalLabelWidth
            needsLayout = true
        }
    }

    init(strip: GroupedTabStrip, groupID: UUID) {
        self.groupID = groupID
        super.init(strip: strip)
        label.font = Self.font
        label.textColor = .labelColor
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ group: TabOrganization.GroupPresentation) {
        if group.name != name || label.stringValue != group.name {
            name = group.name
            label.stringValue = name
            labelWidth = naturalLabelWidth
            toolTip = name
        }
        isActive = group.isActive
        color = group.color
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        memberCount = group.tabs.count
        needsLayout = true
        needsDisplay = true
    }

    override func performPrimaryAction() {
        strip?.request(.activateGroup(groupID))
    }

    // MARK: Layout

    private var chromeWidth: CGFloat {
        Metrics.horizontalPadding * 2 + Metrics.chevronWidth + Metrics.iconSpacing
    }

    var naturalWidth: CGFloat {
        chromeWidth + max(Metrics.groupMinLabelWidth, min(labelWidth, Metrics.groupMaxLabelWidth))
    }
    override var minimumWidth: CGFloat { chromeWidth + Metrics.groupMinLabelWidth }

    override func layout() {
        super.layout()
        let x = Metrics.horizontalPadding + Metrics.chevronWidth + Metrics.iconSpacing
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: floor((bounds.height - height) / 2),
                             width: max(0, bounds.maxX - Metrics.horizontalPadding - x), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isPressed {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.10 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius).fill()
        }
        let chevronRect = NSRect(x: Metrics.horizontalPadding, y: 0, width: Metrics.chevronWidth, height: bounds.height)
        Self.drawChevron(in: chevronRect, down: isActive,
                         color: isPressed || isHovered || isActive ? .labelColor : .secondaryLabelColor)
    }

    private static func drawChevron(in rect: NSRect, down: Bool, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let size: CGFloat = 3
        let midX = rect.midX
        let midY = rect.midY
        if down {
            path.move(to: NSPoint(x: midX - size, y: midY + size / 2))
            path.line(to: NSPoint(x: midX, y: midY - size / 2))
            path.line(to: NSPoint(x: midX + size, y: midY + size / 2))
        } else {
            path.move(to: NSPoint(x: midX - size / 2, y: midY + size))
            path.line(to: NSPoint(x: midX + size / 2, y: midY))
            path.line(to: NSPoint(x: midX - size / 2, y: midY - size))
        }
        color.setStroke()
        path.stroke()
    }

    // MARK: Accessibility

    override var itemTitle: String { name }
    override func accessibilityValue() -> Any? { isActive ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { isActive }

    override func accessibilityHelp() -> String? {
        memberCount == 1 ? "Tab group with 1 tab" : "Tab group with \(memberCount) tabs"
    }
}

// MARK: - Chrome

/// Overflow affordance shown at a clipped edge of the scrolling row; presses scroll a page.
private final class GroupedStripScrollButton: NSView {
    enum Direction { case left, right }

    let direction: Direction
    var onPress: (() -> Void)?

    init(direction: Direction) {
        self.direction = direction
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(direction == .left ? "Scroll tabs left" : "Scroll tabs right")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let size: CGFloat = 3
        let midX = bounds.midX
        let midY = bounds.midY
        let sign: CGFloat = direction == .left ? -1 : 1
        path.move(to: NSPoint(x: midX - sign * size / 2, y: midY + size))
        path.line(to: NSPoint(x: midX + sign * size / 2, y: midY))
        path.line(to: NSPoint(x: midX - sign * size / 2, y: midY - size))
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { onPress != nil }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
