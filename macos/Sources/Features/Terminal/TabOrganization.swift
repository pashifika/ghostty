#if os(macOS)
import Cocoa

/// Metadata over native terminal windows. This type never constructs a terminal or decodes a surface tree.
@MainActor
final class TabOrganization {
    static let shared = TabOrganization()
    static let didChange = Notification.Name("TabOrganizationDidChange")

    struct TabPresentation: Identifiable, Equatable {
        let id: UUID
        let title: String
        let color: TerminalTabColor
        let isSelected: Bool
    }

    struct GroupPresentation: Identifiable, Equatable {
        let id: UUID
        let name: String
        let tabs: [TabPresentation]
        let isActive: Bool
    }

    struct Presentation: Equatable {
        let windowID: UUID
        let groups: [GroupPresentation]
        let unassigned: [TabPresentation]
        let selectedTabID: UUID?
        let activeGroupID: UUID?
    }

    enum Action {
        case activateTab(UUID)
        case activateGroup(UUID)
        case createGroup(tabID: UUID)
        case renameGroup(UUID)
        case deleteGroup(UUID)
        case moveTab(tabID: UUID, groupID: UUID?, index: Int?)
        case moveGroup(groupID: UUID, index: Int)
        case closeTab(UUID)
        case detachTab(UUID, screenPoint: NSPoint)
    }

    struct UndoContext {
        let identity: TabOrganizationIdentity
        let group: TabOrganizationState.Group?
        let groupIndex: Int?
        let tabIndex: Int
    }

    @MainActor
    private struct NativeWindow {
        let key: ObjectIdentifier
        let windows: [TerminalWindow]
        var tabIDs: [UUID] { windows.compactMap { $0.terminalController?.organizationIdentity.tabID } }
        var selectedTabID: UUID? {
            guard let first = windows.first else { return nil }
            let group = first.tabGroup
            let selected: NSWindow? = group == nil ? first : group?.selectedWindow
            return (selected?.windowController as? TerminalController)?.organizationIdentity.tabID
        }
    }

    private struct RestoreRequest {
        var completionReturned = false
        var bodyReturned = false
        var focusFinished = true
        var focusSucceeded = false
        var focus: Weak<Ghostty.SurfaceView>?
        var window: Weak<NSWindow>?
    }

    private let store = TabOrganizationStore(defaults: .ghostty)
    private var state = TabOrganizationState()
    private var pendingState: TabOrganizationState?
    private var controllers: [Weak<TerminalController>] = []
    private var nativeOwners: [ObjectIdentifier: UUID] = [:]
    private var groupObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var runLoopObserver: CFRunLoopObserver?
    private var requests: [UUID: RestoreRequest] = [:]
    private var nativeRestorationFinished = false
    private var didFinishLaunching = false
    private var didBecomeActive = false
    private var restoring = true
    var isRestoring: Bool { restoring }
    private var started = false
    private var terminating = false
    private var saveEnabled = false
    private var reconciling = false
    private var nativeOperationPending = false
    private var observationScheduled = false
    private var observationPending = false
    private var explicitEditPending = false
    private var lastSavedState: TabOrganizationState?
    private var lastInvalidatedState: TabOrganizationState?
    private var lastPresentation: [UUID: Presentation] = [:]
    private var lastPublishedRestoring = true
    private var undoContexts: [UUID: UndoContext] = [:]
    private var creationContexts: [UUID: (parent: UUID, atEnd: Bool)] = [:]
    private var mergeDestination: Weak<TerminalWindow>?
    private var departingTabs = Set<UUID>()
    private var deletingGroups = Set<UUID>()

    private init() {}

    // MARK: Native restoration and observation

    func start(config: Ghostty.Config) {
        guard !started else { return }
        started = true
        saveEnabled = config.windowSaveState != "never"
        if saveEnabled {
            do { pendingState = try store.load() } catch { Ghostty.logger.error("Cannot load tab organization: \(error.localizedDescription)") }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nativeRestorationFinished = true
                self?.nativeStateDidChange()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
                self?.terminating = true
            }
        })
        // The documented AppKit barrier can occur inside completionHandler. Drain its return,
        // the restore body, and SwiftUI focus propagation before applying any saved metadata.
        runLoopObserver = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            guard let self, self.observationPending, !self.observationScheduled else { return }
            self.observationPending = false
            self.flush(restorationBoundary: true)
        }
        if let runLoopObserver { CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
    }

    func configurationDidChange(_ config: Ghostty.Config) {
        saveEnabled = config.windowSaveState != "never"
        if !saveEnabled { pendingState = nil }
        // Re-enabling saving does not apply an old snapshot over live terminals.
        nativeStateDidChange()
    }

    func applicationDidFinishLaunching() {
        didFinishLaunching = true
        nativeStateDidChange()
    }

    func applicationDidBecomeActive() {
        didBecomeActive = true
        nativeStateDidChange()
    }

    func nativeRestoreBegan() -> UUID {
        let id = UUID()
        requests[id] = RestoreRequest()
        return id
    }

    func nativeRestoreCompleted(_ id: UUID, window: NSWindow?, error: Error?) {
        requests[id]?.completionReturned = true
        if let error { Ghostty.logger.error("Native tab restoration failed: \(error.localizedDescription)") }
        nativeStateDidChange()
    }

    func nativeRestoreBodyFinished(_ id: UUID) {
        requests[id]?.bodyReturned = true
        nativeStateDidChange()
    }

    func nativeFocusPending(_ id: UUID, window: NSWindow, surface: Ghostty.SurfaceView) {
        requests[id]?.focusFinished = false
        requests[id]?.focus = Weak(surface)
        requests[id]?.window = Weak(window)
    }

    func nativeFocusFinished(_ id: UUID, succeeded: Bool) {
        requests[id]?.focusFinished = true
        requests[id]?.focusSucceeded = succeeded
        if !succeeded { Ghostty.logger.error("Native tab restoration could not restore its terminal responder") }
        nativeStateDidChange()
    }

    func register(_ controller: TerminalController) {
        guard !controllers.contains(where: { $0.value === controller }) else { return }
        controllers.append(Weak(controller))
        nativeStateDidChange()
    }

    func unregister(_ controller: TerminalController) {
        controllers.removeAll { $0.value == nil || $0.value === controller }
        nativeStateDidChange()
    }

    func capturedStateDidChange(_ controller: TerminalController) {
        guard !controller.organizationWindowClosed else { return }
        controller.invalidateRestorableState()
        controller.window?.invalidateRestorableState()
        nativeStateDidChange()
    }

    func nativeStateDidChange() {
        guard !terminating else { return }
        observationPending = true
        guard !observationScheduled else { return }
        observationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observationScheduled = false
            self.observeGroups()
        }
    }

    private var liveControllers: [TerminalController] {
        controllers.compactMap(\.value).filter { !$0.organizationWindowClosed }
    }

    private func nativeWindows() -> [NativeWindow] {
        let live = liveControllers
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        var seen = Set<ObjectIdentifier>()
        return live.compactMap { controller in
            guard let window = controller.window as? TerminalWindow else { return nil }
            let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            guard seen.insert(key).inserted else { return nil }
            let windows = (window.tabGroup?.windows ?? [window]).compactMap { candidate -> TerminalWindow? in
                guard let candidate = candidate as? TerminalWindow, let owner = candidate.terminalController,
                      liveIDs.contains(ObjectIdentifier(owner)) else { return nil }
                return candidate
            }
            return NativeWindow(key: key, windows: windows)
        }
    }

    private func observeGroups() {
        var groups: [ObjectIdentifier: NSWindowTabGroup] = [:]
        for controller in liveControllers {
            if let group = controller.window?.tabGroup { groups[ObjectIdentifier(group)] = group }
        }
        for key in Array(groupObservations.keys) where groups[key] == nil { groupObservations.removeValue(forKey: key) }
        for (key, group) in groups where groupObservations[key] == nil {
            groupObservations[key] = [
                group.observe(\.windows, options: [.old, .new]) { [weak self] group, change in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if !self.reconciling, !self.nativeOperationPending, !group.windows.isEmpty {
                            let remaining = Set(group.windows.map(ObjectIdentifier.init))
                            for window in change.oldValue ?? [] where !remaining.contains(ObjectIdentifier(window)) {
                                if let controller = window.windowController as? TerminalController {
                                    self.departingTabs.insert(controller.organizationIdentity.tabID)
                                }
                            }
                        }
                        self.nativeStateDidChange()
                    }
                },
                group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.nativeStateDidChange() }
                }
            ]
        }
    }

    func flush(restorationBoundary: Bool = false) {
        guard started, !reconciling, !nativeOperationPending, !terminating else { return }
        observeGroups()
        if restoring {
            guard restorationBoundary, nativeRestorationFinished, didFinishLaunching, didBecomeActive,
                  requests.values.allSatisfy({ $0.completionReturned && $0.bodyReturned && $0.focusFinished }),
                  nativeWindows().allSatisfy({ bucket in
                      guard let selected = bucket.selectedTabID else { return false }
                      return bucket.tabIDs.contains(selected)
                  }) else { return }
            for request in requests.values where request.focusSucceeded {
                guard request.focus?.value != nil, let window = request.window?.value else { continue }
                // A closed/failed restored window must not hold the entire application behind the barrier.
                guard let controller = window.windowController as? TerminalController,
                      !controller.organizationWindowClosed else { continue }
                // Observe the actual responder, not historical selection: the user may have
                // selected another split while native restoration was finishing.
                guard let focused = controller.focusedSurface, focused.window === window,
                      window.firstResponder === focused else { return }
            }
            state = saveEnabled ? pendingState ?? .init() : .init()
            pendingState = nil
            reconcile(restoring: true)
            restoring = false
            requests.removeAll()
        } else {
            reconcile()
        }
        publish()
    }

    /// Read back only real native windows. Saved identities never cause a cross-window move.
    private func reconcile(restoring restore: Bool = false, repairOrder: Bool = true) {
        guard !reconciling else { return }
        reconciling = true
        defer {
            reconciling = false
            // A native insertion can fail after detaching a living window. Include that new
            // physical window in the same committed readback, without retrying the failed move.
            let actual = nativeWindows()
            if repairOrder, Set(actual.flatMap(\.tabIDs)) != Set(state.windows.flatMap(\.tabIDs)) {
                reconcile(repairOrder: false)
            }
        }
        controllers.removeAll { $0.value == nil || $0.value?.organizationWindowClosed == true }
        let live = liveControllers
        let duplicates = Dictionary(grouping: live, by: { $0.organizationIdentity.tabID }).filter { $0.value.count > 1 }
        for (_, owners) in duplicates {
            Ghostty.logger.error("Duplicate native organization tab identity; keeping each terminal unassigned with a fresh identity")
            for owner in owners {
                undoContexts.removeValue(forKey: owner.organizationIdentity.tabID)
                owner.organizationIdentity.tabID = UUID()
            }
        }
        let native = nativeWindows()
        let previous = state.windows
        let livingIDs = Set(native.flatMap(\.tabIDs))
        let keys = Set(native.map(\.key))
        nativeOwners = nativeOwners.filter { keys.contains($0.key) }
        var reserved = Set(nativeOwners.values)
        var next: [TabOrganizationState.Window] = []
        let mergeKey = (mergeDestination?.value).map { $0.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier($0) }
        if let mergeKey, nativeOwners[mergeKey] == nil,
           let id = mergeDestination?.value?.terminalController?.organizationIdentity.windowID,
           !reserved.contains(id) {
            nativeOwners[mergeKey] = id
            reserved.insert(id)
        }
        // AppKit can replace a two-tab NSWindowTabGroup when one tab tears off. Its
        // remaining members, not the departing tab or controller enumeration order,
        // retain the source's organization-window identity.
        for source in previous where !reserved.contains(source.id) {
            let sourceMembers = Set(source.tabIDs)
            let remainingMembers = sourceMembers.subtracting(departingTabs)
            let candidates = native.filter {
                nativeOwners[$0.key] == nil && !sourceMembers.isDisjoint(with: $0.tabIDs)
            }
            if let owner = candidates.max(by: {
                let lhs = remainingMembers.intersection($0.tabIDs).count
                let rhs = remainingMembers.intersection($1.tabIDs).count
                if lhs != rhs { return lhs < rhs }
                return sourceMembers.intersection($0.tabIDs).count < sourceMembers.intersection($1.tabIDs).count
            }) {
                nativeOwners[owner.key] = source.id
                reserved.insert(source.id)
            }
        }
        for bucket in native {
            guard !bucket.windows.isEmpty else { continue }
            let nativeIDs = bucket.tabIDs
            let members = Set(nativeIDs)
            let owner: UUID
            if let existing = nativeOwners[bucket.key] {
                owner = existing
            } else {
                let candidates = bucket.windows.compactMap { $0.terminalController?.organizationIdentity.windowID }
                owner = candidates.first(where: { !reserved.contains($0) }) ?? UUID()
                reserved.insert(owner)
                nativeOwners[bucket.key] = owner
            }
            var record = previous.first(where: { $0.id == owner }) ?? .init(id: owner)
            let ownedIDs = Set(bucket.windows.compactMap { window -> UUID? in
                guard let identity = window.terminalController?.organizationIdentity,
                      identity.windowID == owner else { return nil }
                return identity.tabID
            })
            record = Model.retaining(record, tabs: ownedIDs, order: restore ? nil : nativeIDs)
            if mergeKey == bucket.key {
                for source in previous where source.id != owner {
                    let transferred = Model.retaining(source, tabs: members, order: nil)
                    for group in transferred.groups where !record.groups.contains(where: { $0.id == group.id }) {
                        let original = source.groups.first { $0.id == group.id }
                        // A partial native merge must not clone a group ID into two physical windows.
                        guard Set(original?.tabIDs ?? []).intersection(livingIDs).isSubset(of: members) else {
                            Ghostty.logger.error("Native merge transferred only part of a tab group; transferred tabs remain unassigned")
                            continue
                        }
                        record.groups.append(group)
                    }
                    record.unassigned.append(contentsOf: transferred.unassigned.filter { !record.tabIDs.contains($0) })
                }
            }
            let known = Set(record.tabIDs)
            record.unassigned.append(contentsOf: nativeIDs.filter { !known.contains($0) })
            let observedRecord = record
            var returning: [UndoContext] = []
            for tabID in nativeIDs {
                if let context = creationContexts[tabID], members.contains(context.parent) {
                    let group = record.groups.first(where: { $0.tabIDs.contains(context.parent) })
                    let partition = group?.tabIDs ?? record.unassigned
                    let index = context.atEnd ? nil : partition.firstIndex(of: context.parent).map { $0 + 1 }
                    Model.move(tabID, to: group?.id, index: index, in: &record)
                }
                if let context = undoContexts[tabID], context.identity.windowID == owner {
                    let groupExistsElsewhere = context.group.map { group in
                        previous.contains { source in
                            source.id != owner && source.groups.contains {
                                $0.id == group.id && $0.tabIDs.contains { !members.contains($0) }
                            }
                        }
                    } ?? false
                    if !groupExistsElsewhere { returning.append(context) }
                }
            }
            Model.restore(returning, in: &record)
            if !isGrouped(bucket.windows[0]) {
                record.groups = []
                record.unassigned = nativeIDs
            }
            let selected = restore && record.selectedTabID.map(members.contains) == true
                ? record.selectedTabID : bucket.selectedTabID
            Model.select(selected ?? nativeIDs.first, in: &record)
            if record.tabIDs != nativeIDs {
                if !repairOrder || !applyNativeOrder(record.tabIDs, in: bucket) {
                    Ghostty.logger.error("Native tab order did not complete; reconciling organization to actual surviving tabs")
                    let actual = readback(of: bucket)?.tabIDs ?? []
                    record = Model.nativeFallback(observedRecord, order: actual)
                }
            }
            if restore, let selected = record.selectedTabID,
               let window = bucket.windows.first(where: { $0.terminalController?.organizationIdentity.tabID == selected }) {
                selectNative(window, activate: window.tabGroup?.windows.contains(where: \.isKeyWindow) == true)
            }
            let actual = readback(of: bucket)
            if let actual, actual.key != bucket.key {
                nativeOwners.removeValue(forKey: bucket.key)
                nativeOwners[actual.key] = owner
            }
            record = Model.retaining(record, tabs: Set(actual?.tabIDs ?? []), order: nil)
            if actual?.selectedTabID == nil, let first = actual?.windows.first {
                selectNative(first, activate: false)
            }
            Model.select(actual?.selectedTabID, in: &record)
            for window in actual?.windows ?? [] {
                window.terminalController?.organizationIdentity.windowID = owner
            }
            if !record.tabIDs.isEmpty { next.append(record) }
        }
        state.windows = next
        creationContexts = creationContexts.filter { context in !next.contains(where: { $0.tabIDs.contains(context.key) }) }
        undoContexts = undoContexts.filter { context in !next.contains(where: { $0.tabIDs.contains(context.key) }) }
        mergeDestination = nil
        departingTabs.removeAll()
        observeGroups()
    }

    private func readback(of bucket: NativeWindow) -> NativeWindow? {
        let actual = nativeWindows()
        if let same = actual.first(where: { $0.key == bucket.key }) { return same }
        let members = Set(bucket.tabIDs)
        let remaining = members.subtracting(departingTabs)
        return actual.filter { !members.isDisjoint(with: $0.tabIDs) }.max {
            let lhs = remaining.intersection($0.tabIDs).count
            let rhs = remaining.intersection($1.tabIDs).count
            if lhs != rhs { return lhs < rhs }
            return members.intersection($0.tabIDs).count < members.intersection($1.tabIDs).count
        }
    }

    private func applyNativeOrder(_ order: [UUID], in bucket: NativeWindow) -> Bool {
        guard Set(order) == Set(bucket.tabIDs), order.count == bucket.windows.count else { return false }
        if order == bucket.tabIDs { return true }
        guard let anchor = bucket.windows.first else { return order.isEmpty }
        let selected = anchor.tabGroup?.selectedWindow ?? anchor
        let wasKey = bucket.windows.contains(where: \.isKeyWindow)
        let responder = selected.firstResponder
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer {
            if selected.tabGroup?.windows.contains(selected) == true {
                selected.tabGroup?.selectedWindow = selected
                if wasKey { selected.makeKey() }
                if let responder { selected.makeFirstResponder(responder) }
            }
            NSAnimationContext.endGrouping()
        }
        for (index, id) in order.enumerated() {
            guard let group = anchor.tabGroup, group.windows.count == order.count,
                  let moving = bucket.windows.first(where: { $0.terminalController?.organizationIdentity.tabID == id }),
                  group.windows.contains(moving) else { return false }
            if group.windows[index] === moving { continue }
            let target = group.windows[index]
            group.removeWindow(moving)
            guard target.addTabbedWindowSafely(moving, ordered: .below) else {
                departingTabs.insert(id)
                return false
            }
        }
        return anchor.tabGroup?.windows.compactMap {
            ($0.windowController as? TerminalController)?.organizationIdentity.tabID
        } == order
    }

    private func publish() {
        let native = nativeWindows()
        var presentations: [UUID: Presentation] = [:]
        for bucket in native {
            guard let window = bucket.windows.first else { continue }
            let value = presentation(for: window)
            presentations[value.windowID] = value
        }
        // Completion is observable even when AppKit restores no windows.
        if presentations != lastPresentation || restoring != lastPublishedRestoring {
            lastPresentation = presentations
            lastPublishedRestoring = restoring
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        guard !restoring else { return }
        if state != lastInvalidatedState {
            lastInvalidatedState = state
            for controller in liveControllers {
                controller.invalidateRestorableState()
                controller.window?.invalidateRestorableState()
            }
            NSApp.invalidateRestorableState()
        }
        guard saveEnabled, !store.hasInvalidState || explicitEditPending else {
            explicitEditPending = false
            return
        }
        let eligible = Set(liveControllers.filter { $0.window?.isRestorable == true }.map { $0.organizationIdentity.tabID })
        var snapshot = state
        snapshot.windows = snapshot.windows.map { Model.retaining($0, tabs: eligible, order: nil) }.filter { !$0.tabIDs.isEmpty }
        guard snapshot != lastSavedState || explicitEditPending else { return }
        do {
            try store.save(snapshot, explicitEdit: explicitEditPending)
            lastSavedState = snapshot
            explicitEditPending = false
        } catch {
            Ghostty.logger.error("Cannot save tab organization: \(error.localizedDescription)")
        }
    }

    // MARK: Lifecycle intents (metadata stays provisional until readback)

    func tabCreated(_ controller: TerminalController, from parent: TerminalController, atEnd: Bool) {
        guard let window = parent.window as? TerminalWindow, isGrouped(window) else { return }
        creationContexts[controller.organizationIdentity.tabID] = (parent.organizationIdentity.tabID, atEnd)
        nativeStateDidChange()
    }

    func undoContext(for controller: TerminalController) -> UndoContext? {
        guard !restoring else { return nil }
        let identity = controller.organizationIdentity
        guard let record = state.windows.first(where: { $0.tabIDs.contains(identity.tabID) }) else { return nil }
        let groupIndex = record.groups.firstIndex(where: { $0.tabIDs.contains(identity.tabID) })
        let group = groupIndex.map { record.groups[$0] }
        return .init(identity: identity, group: group, groupIndex: groupIndex,
                     tabIndex: (group?.tabIDs ?? record.unassigned).firstIndex(of: identity.tabID) ?? 0)
    }

    func tabRestored(_ controller: TerminalController, context: UndoContext?) {
        if let context { undoContexts[controller.organizationIdentity.tabID] = context }
        nativeStateDidChange()
    }

    func willMergeWindows(into window: TerminalWindow) {
        flush()
        mergeDestination = Weak(window)
        nativeOperationPending = true
    }

    func didMergeWindows() {
        // AppKit publishes the merged group on its queued native operation. Observe after that
        // delivery and the main-loop boundary, never during the call to super.mergeAllWindows.
        DispatchQueue.main.async { [weak self] in
            self?.nativeOperationPending = false
            self?.nativeStateDidChange()
        }
    }

    /// Existing move_tab actions address the flattened order, including collapsed groups.
    func moveTab(_ controller: TerminalController, by amount: Int) -> Bool {
        guard let window = controller.window as? TerminalWindow, isGrouped(window) else { return false }
        flush()
        guard let record = record(for: window), let start = record.tabIDs.firstIndex(of: controller.organizationIdentity.tabID) else { return true }
        let end = amount < 0 ? start - min(start, amount == Int.min ? Int.max : -amount)
            : start + min(record.tabIDs.count - start - 1, amount)
        guard start != end else { return true }
        let target = record.tabIDs[end]
        let group = record.groups.first(where: { $0.tabIDs.contains(target) })
        let partition = (group?.tabIDs ?? record.unassigned).filter { $0 != controller.organizationIdentity.tabID }
        let index = (partition.firstIndex(of: target) ?? partition.count) + (amount > 0 ? 1 : 0)
        _ = moveTab(controller.organizationIdentity.tabID, to: group?.id, index: index, in: window)
        return true
    }

    // MARK: Semantic frontend boundary

    private func isGrouped(_ window: TerminalWindow) -> Bool {
        (window.tabGroup?.windows ?? [window]).contains { $0 is GroupedTitlebarTerminalWindow }
    }

    private func record(for window: TerminalWindow) -> TabOrganizationState.Window? {
        guard let id = window.terminalController?.organizationIdentity.tabID else { return nil }
        return state.windows.first(where: { $0.tabIDs.contains(id) })
    }

    func presentation(for window: TerminalWindow) -> Presentation {
        let windows = (window.tabGroup?.windows ?? [window]).compactMap { $0 as? TerminalWindow }
            .filter { $0.terminalController?.organizationWindowClosed == false }
        let nativeGroup = window.tabGroup
        let selectedWindow: NSWindow? = nativeGroup == nil ? window : nativeGroup?.selectedWindow
        let selected = (selectedWindow?.windowController as? TerminalController)?.organizationIdentity.tabID
        let byID = Dictionary(windows.compactMap { window -> (UUID, TabPresentation)? in
            guard let id = window.terminalController?.organizationIdentity.tabID else { return nil }
            return (id, .init(id: id, title: window.title, color: window.tabColor, isSelected: selected == id))
        }, uniquingKeysWith: { first, _ in first })
        let record = record(for: window)
        let groups = record?.groups.compactMap { group -> GroupPresentation? in
            let tabs = group.tabIDs.compactMap { byID[$0] }
            guard !tabs.isEmpty else { return nil }
            return .init(id: group.id, name: group.name, tabs: tabs, isActive: tabs.contains(where: \.isSelected))
        } ?? []
        let grouped = Set(groups.flatMap { $0.tabs.map(\.id) })
        let unassigned = windows.compactMap { $0.terminalController?.organizationIdentity.tabID }
            .filter { !grouped.contains($0) }.compactMap { byID[$0] }
        return .init(windowID: record?.id ?? window.terminalController?.organizationIdentity.windowID ?? UUID(),
                     groups: groups, unassigned: unassigned, selectedTabID: selected,
                     activeGroupID: groups.first(where: \.isActive)?.id)
    }

    func perform(_ action: Action, in window: TerminalWindow) {
        flush()
        guard !restoring, !nativeOperationPending, isGrouped(window) else { return }
        switch action {
        case .activateTab(let id):
            guard let target = tab(id, in: window) else { return }
            selectNative(target, activate: true)
            flush()
        case .activateGroup(let id):
            guard let record = record(for: window), let group = record.groups.first(where: { $0.id == id }) else { return }
            let selected = record.activeGroupID == id ? record.selectedTabID
                : group.lastSelectedTabID.flatMap { group.tabIDs.contains($0) ? $0 : nil } ?? group.tabIDs.first
            if let selected { perform(.activateTab(selected), in: window) }
        case .createGroup(let id):
            promptName(title: "Create Tab Group", name: "", in: window) { [weak self, weak window] name in
                guard let self, let window else { return }
                _ = self.createGroup(from: id, name: name, in: window)
            }
        case .renameGroup(let id):
            guard let group = record(for: window)?.groups.first(where: { $0.id == id }) else { return }
            promptName(title: "Rename Tab Group", name: group.name, in: window) { [weak self, weak window] name in
                guard let self, let window else { return }
                _ = self.renameGroup(id, name: name, in: window)
            }
        case .deleteGroup(let id): promptDeletion(id, in: window)
        case .moveTab(let id, let groupID, let index): _ = moveTab(id, to: groupID, index: index, in: window)
        case .moveGroup(let id, let index): _ = moveGroup(id, index: index, in: window)
        case .closeTab(let id): tab(id, in: window)?.terminalController?.closeTab(nil)
        case .detachTab(let id, let point):
            guard let target = tab(id, in: window), (target.tabGroup?.windows.count ?? 0) > 1 else { return }
            target.moveTabToNewWindow(nil)
            DispatchQueue.main.async { [weak self, weak target] in
                guard let self, let target else { return }
                if (target.tabGroup?.windows.count ?? 1) == 1 {
                    target.setFrameTopLeftPoint(point)
                    target.constrainToScreen()
                } else {
                    Ghostty.logger.error("Native tab detach did not complete")
                }
                self.flush()
            }
        }
    }

    @discardableResult
    func createGroup(from tabID: UUID, name: String, in window: TerminalWindow) -> Bool {
        flush()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var record = record(for: window), record.tabIDs.contains(tabID) else { return false }
        Model.remove(tabID, from: &record)
        record.groups.append(.init(id: UUID(), name: name, tabIDs: [tabID], lastSelectedTabID: tabID))
        return commit(record, in: window)
    }

    @discardableResult
    func renameGroup(_ groupID: UUID, name: String, in window: TerminalWindow) -> Bool {
        flush()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var record = record(for: window), let index = record.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        record.groups[index].name = name
        return commit(record, in: window)
    }

    @discardableResult
    func moveTab(_ tabID: UUID, to groupID: UUID?, index: Int?, in window: TerminalWindow) -> Bool {
        flush()
        guard var record = record(for: window), Model.move(tabID, to: groupID, index: index, in: &record) else { return false }
        return commit(record, in: window)
    }

    @discardableResult
    func moveGroup(_ groupID: UUID, index: Int, in window: TerminalWindow) -> Bool {
        flush()
        guard var record = record(for: window), let current = record.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let group = record.groups.remove(at: current)
        record.groups.insert(group, at: min(max(0, index), record.groups.count))
        return commit(record, in: window)
    }

    @discardableResult
    func deleteGroupKeepingTabs(_ groupID: UUID, in window: TerminalWindow) -> Bool {
        flush()
        guard var record = record(for: window), Model.dissolve(groupID, in: &record) else { return false }
        return commit(record, in: window)
    }

    private func commit(_ candidate: TabOrganizationState.Window, in window: TerminalWindow) -> Bool {
        guard !restoring, !reconciling, !nativeOperationPending, isGrouped(window),
              let index = state.windows.firstIndex(where: { $0.id == candidate.id }),
              let bucket = nativeWindows().first(where: { $0.windows.contains(window) }),
              Set(candidate.tabIDs) == Set(bucket.tabIDs) else { return false }
        var candidate = candidate
        Model.select(bucket.selectedTabID, in: &candidate)
        guard candidate != state.windows[index] else { return true }
        reconciling = true
        let success = applyNativeOrder(candidate.tabIDs, in: bucket)
        reconciling = false
        guard success else {
            Ghostty.logger.error("Tab organization move failed; intended metadata was not committed")
            reconcile(repairOrder: false)
            publish()
            return false
        }
        state.windows[index] = candidate
        explicitEditPending = true
        publish()
        return true
    }

    private func tab(_ id: UUID, in window: TerminalWindow) -> TerminalWindow? {
        (window.tabGroup?.windows ?? [window]).compactMap { $0 as? TerminalWindow }.first {
            $0.terminalController?.organizationIdentity.tabID == id && $0.terminalController?.organizationWindowClosed == false
        }
    }

    private func selectNative(_ window: TerminalWindow, activate: Bool) {
        window.tabGroup?.selectedWindow = window
        if activate { window.makeKeyAndOrderFront(nil) }
        if let surface = window.terminalController?.focusedSurface { window.makeFirstResponder(surface) }
        nativeStateDidChange()
    }

    private func promptName(title: String, name: String, in window: TerminalWindow, completion: @escaping (String) -> Void) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = name
        field.setAccessibilityLabel("Group name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue)
        }
    }

    private func promptDeletion(_ id: UUID, in window: TerminalWindow) {
        guard window.attachedSheet == nil, let group = record(for: window)?.groups.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Tab Group?"
        alert.informativeText = "Delete “\(group.name)”? Its tabs will be kept unless you also choose to close them."
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        let checkbox = NSButton(checkboxWithTitle: "Also close tabs", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard response == .alertFirstButtonReturn, let self, let window else { return }
            if checkbox.state == .on {
                // Let AppKit finish removing this sheet before presenting a per-tab close sheet.
                DispatchQueue.main.async { self.deleteGroupClosingTabs(id, in: window) }
            } else {
                _ = self.deleteGroupKeepingTabs(id, in: window)
            }
        }
    }

    /// Submit one protected per-tab close at a time. A cancellation never undoes a completed close.
    func deleteGroupClosingTabs(_ id: UUID, in window: TerminalWindow) {
        flush()
        guard let record = record(for: window), let group = record.groups.first(where: { $0.id == id }),
              deletingGroups.insert(id).inserted else { return }
        closeNext(group.tabIDs[...], groupID: id, windowID: record.id)
    }

    private func closeNext(_ remaining: ArraySlice<UUID>, groupID: UUID, windowID: UUID) {
        flush()
        guard !restoring, !nativeOperationPending, let id = remaining.first else {
            deletingGroups.remove(groupID)
            return
        }
        guard let record = state.windows.first(where: { $0.id == windowID }),
              record.groups.contains(where: { $0.id == groupID && $0.tabIDs.contains(id) }),
              let controller = liveControllers.first(where: { $0.organizationIdentity.tabID == id }) else {
            deletingGroups.remove(groupID)
            return
        }
        controller.closeTabWithCompletion { [weak self] closed in
            guard let self else { return }
            self.flush()
            guard closed else {
                self.deletingGroups.remove(groupID)
                return
            }
            self.closeNext(remaining.dropFirst(), groupID: groupID, windowID: windowID)
        }
    }

    func contextMenu(for tabID: UUID, in window: TerminalWindow) -> NSMenu? {
        flush()
        guard let target = tab(tabID, in: window), let menu = window.makeTabContextMenu(for: target) else { return nil }
        menu.addItem(.separator())
        menu.addItem(MenuItem("Create Group...", action: .createGroup(tabID: tabID), window: window))
        let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to Group")
        for group in record(for: window)?.groups ?? [] {
            submenu.addItem(MenuItem(group.name, action: .moveTab(tabID: tabID, groupID: group.id, index: nil), window: window))
        }
        submenu.addItem(.separator())
        submenu.addItem(MenuItem("Unassigned", action: .moveTab(tabID: tabID, groupID: nil, index: nil), window: window))
        move.submenu = submenu
        menu.addItem(move)
        return menu
    }

    func groupContextMenu(for groupID: UUID, in window: TerminalWindow) -> NSMenu {
        flush()
        let menu = NSMenu(title: "Tab Group")
        guard let record = record(for: window), let index = record.groups.firstIndex(where: { $0.id == groupID }) else { return menu }
        menu.addItem(MenuItem("Activate Group", action: .activateGroup(groupID), window: window))
        menu.addItem(MenuItem("Rename Group...", action: .renameGroup(groupID), window: window))
        if index > 0 { menu.addItem(MenuItem("Move Group Left", action: .moveGroup(groupID: groupID, index: index - 1), window: window)) }
        if index + 1 < record.groups.count { menu.addItem(MenuItem("Move Group Right", action: .moveGroup(groupID: groupID, index: index + 1), window: window)) }
        menu.addItem(.separator())
        menu.addItem(MenuItem("Delete Group...", action: .deleteGroup(groupID), window: window))
        return menu
    }

    private final class MenuItem: NSMenuItem {
        private let organizationAction: Action
        private weak var window: TerminalWindow?

        init(_ title: String, action: Action, window: TerminalWindow) {
            self.organizationAction = action
            self.window = window
            super.init(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        @MainActor
        @objc private func invoke(_ sender: NSMenuItem) {
            guard let window else { return }
            TabOrganization.shared.perform(organizationAction, in: window)
        }
    }

    // MARK: Partition transitions, independent of AppKit lifecycle

    enum Model {
        static func select(_ tabID: UUID?, in window: inout TabOrganizationState.Window) {
            window.selectedTabID = tabID.flatMap { id in
                window.unassigned.contains(id) || window.groups.contains(where: { $0.tabIDs.contains(id) }) ? id : nil
            }
            window.activeGroupID = nil
            guard let selected = window.selectedTabID,
                  let index = window.groups.firstIndex(where: { $0.tabIDs.contains(selected) }) else { return }
            window.activeGroupID = window.groups[index].id
            window.groups[index].lastSelectedTabID = selected
        }

        static func remove(_ tabID: UUID, from window: inout TabOrganizationState.Window) {
            window.unassigned.removeAll { $0 == tabID }
            for index in window.groups.indices {
                window.groups[index].tabIDs.removeAll { $0 == tabID }
                if window.groups[index].lastSelectedTabID == tabID { window.groups[index].lastSelectedTabID = nil }
            }
            window.groups.removeAll { $0.tabIDs.isEmpty }
            select(window.selectedTabID, in: &window)
        }

        @discardableResult
        static func dissolve(_ groupID: UUID, in window: inout TabOrganizationState.Window) -> Bool {
            guard let index = window.groups.firstIndex(where: { $0.id == groupID }) else { return false }
            window.unassigned.append(contentsOf: window.groups.remove(at: index).tabIDs)
            select(window.selectedTabID, in: &window)
            return true
        }

        @discardableResult
        static func move(_ tabID: UUID, to groupID: UUID?, index: Int?, in window: inout TabOrganizationState.Window) -> Bool {
            guard window.tabIDs.contains(tabID), groupID == nil || window.groups.contains(where: { $0.id == groupID }) else { return false }
            let selected = window.selectedTabID
            // Preserve a destination that is also the source's last-member group.
            let destination = window.groups.first(where: { $0.id == groupID })
            let destinationIndex = window.groups.firstIndex(where: { $0.id == groupID })
            remove(tabID, from: &window)
            if let destination, let destinationIndex, !window.groups.contains(where: { $0.id == groupID }) {
                var group = destination
                group.tabIDs = [tabID]
                window.groups.insert(group, at: min(destinationIndex, window.groups.count))
            } else if let group = window.groups.firstIndex(where: { $0.id == groupID }) {
                let target = min(max(0, index ?? window.groups[group].tabIDs.count), window.groups[group].tabIDs.count)
                window.groups[group].tabIDs.insert(tabID, at: target)
            } else {
                window.unassigned.insert(tabID, at: min(max(0, index ?? window.unassigned.count), window.unassigned.count))
            }
            if let destination, let remembered = destination.lastSelectedTabID,
               let target = window.groups.firstIndex(where: { $0.id == destination.id }),
               window.groups[target].tabIDs.contains(remembered) {
                window.groups[target].lastSelectedTabID = remembered
            }
            select(selected, in: &window)
            return true
        }

        static func retaining(_ source: TabOrganizationState.Window, tabs: Set<UUID>, order: [UUID]?) -> TabOrganizationState.Window {
            var result = source
            for index in result.groups.indices {
                let surviving = Set(result.groups[index].tabIDs).intersection(tabs)
                result.groups[index].tabIDs = (order ?? result.groups[index].tabIDs).filter { surviving.contains($0) }
                if let selected = result.groups[index].lastSelectedTabID, !surviving.contains(selected) {
                    result.groups[index].lastSelectedTabID = nil
                }
            }
            result.groups.removeAll { $0.tabIDs.isEmpty }
            let unassigned = Set(result.unassigned).intersection(tabs)
            result.unassigned = (order ?? result.unassigned).filter { unassigned.contains($0) }
            select(result.selectedTabID, in: &result)
            return result
        }

        /// A native window Undo may materialize tabs in reverse insertion order.
        /// Replay saved slots in order so clamping against a partial partition cannot reorder them.
        static func restore(_ contexts: [UndoContext], in window: inout TabOrganizationState.Window) {
            let ordered = contexts.sorted {
                let lhs = $0.groupIndex ?? Int.max
                let rhs = $1.groupIndex ?? Int.max
                return lhs == rhs ? $0.tabIndex < $1.tabIndex : lhs < rhs
            }
            for context in ordered {
                restore(context.identity.tabID, context: context, in: &window)
            }
        }

        static func restore(_ tabID: UUID, context: UndoContext, in window: inout TabOrganizationState.Window) {
            let selected = window.selectedTabID
            remove(tabID, from: &window)
            if let original = context.group {
                if let index = window.groups.firstIndex(where: { $0.id == original.id }) {
                    window.groups[index].tabIDs.insert(tabID, at: min(context.tabIndex, window.groups[index].tabIDs.count))
                } else {
                    var group = original
                    group.tabIDs = [tabID]
                    group.lastSelectedTabID = tabID
                    window.groups.insert(group, at: min(context.groupIndex ?? window.groups.count, window.groups.count))
                }
            } else {
                window.unassigned.insert(tabID, at: min(context.tabIndex, window.unassigned.count))
            }
            select(selected, in: &window)
        }

        /// A failed native reorder cannot be saved as a successful canonical order. Keep only
        /// complete named blocks that really precede the unassigned tail; never hide a live tab.
        static func nativeFallback(_ source: TabOrganizationState.Window, order: [UUID]) -> TabOrganizationState.Window {
            var result = retaining(source, tabs: Set(order), order: order)
            var groups: [TabOrganizationState.Group] = []
            var cursor = 0
            while cursor < order.count {
                guard let group = result.groups.first(where: { $0.tabIDs.first == order[cursor] }),
                      Array(order.dropFirst(cursor).prefix(group.tabIDs.count)) == group.tabIDs else { break }
                groups.append(group)
                cursor += group.tabIDs.count
            }
            result.groups = groups
            result.unassigned = Array(order.dropFirst(cursor))
            select(result.selectedTabID, in: &result)
            return result
        }
    }
}
#endif
