import Cocoa
import Testing
@testable import Ghostty

@MainActor
struct TabOrganizationTests {
    private typealias Model = TabOrganization.Model

    @Test func lastMemberMovePreservesBackgroundSelection() throws {
        let a = UUID(), b = UUID(), c = UUID(), unassigned = UUID()
        let first = UUID(), second = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(),
            groups: [
                .init(id: first, name: "Work", tabIDs: [a], lastSelectedTabID: a),
                .init(id: second, name: "Work", tabIDs: [b, c], lastSelectedTabID: c)
            ],
            unassigned: [unassigned], selectedTabID: c, activeGroupID: second)

        #expect(Model.move(a, to: second, index: 1, in: &window))
        #expect(window.groups.map(\.id) == [second])
        #expect(window.groups[0].tabIDs == [b, a, c])
        #expect(window.selectedTabID == c)
        #expect(window.activeGroupID == second)

        #expect(Model.move(c, to: nil, index: 0, in: &window))
        #expect(window.unassigned == [c, unassigned])
        #expect(window.selectedTabID == c)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func reorderingWithinTheOnlyMemberGroupKeepsItsIdentity() throws {
        let tab = UUID(), groupID = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(), groups: [.init(id: groupID, name: "Only", tabIDs: [tab], lastSelectedTabID: tab)],
            selectedTabID: tab, activeGroupID: groupID)
        let before = window
        #expect(Model.move(tab, to: groupID, index: 0, in: &window))
        #expect(window == before)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func keepingTabsAppendsMembersAndClearsActiveGroup() throws {
        let a = UUID(), b = UUID(), other = UUID(), trailing = UUID()
        let removed = UUID(), retained = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(),
            groups: [
                .init(id: removed, name: "Delete", tabIDs: [a, b], lastSelectedTabID: b),
                .init(id: retained, name: "Keep", tabIDs: [other], lastSelectedTabID: other)
            ],
            unassigned: [trailing], selectedTabID: b, activeGroupID: removed)
        #expect(Model.dissolve(removed, in: &window))
        #expect(window.groups.map(\.id) == [retained])
        #expect(window.tabIDs == [other, trailing, a, b])
        #expect(window.selectedTabID == b)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func undoRecreatesARemovedLastMemberGroupWithoutDuplicatingTabs() throws {
        let closed = UUID(), survivor = UUID(), groupID = UUID(), windowID = UUID()
        let group = TabOrganizationState.Group(id: groupID, name: "Return", tabIDs: [closed], lastSelectedTabID: closed)
        var window = TabOrganizationState.Window(
            id: windowID, groups: [group], unassigned: [survivor], selectedTabID: closed, activeGroupID: groupID)
        let context = TabOrganization.UndoContext(
            identity: .init(tabID: closed, windowID: windowID), group: group, groupIndex: 0, tabIndex: 0)
        Model.remove(closed, from: &window)
        Model.select(survivor, in: &window)
        #expect(window.groups.isEmpty)

        // The native Undo path has returned exactly this tab. Applying its context twice
        // must still leave one member, not clone the old group or its terminal identity.
        window.unassigned.append(closed)
        Model.restore(closed, context: context, in: &window)
        Model.restore(closed, context: context, in: &window)
        #expect(window.groups.map(\.id) == [groupID])
        #expect(window.groups[0].tabIDs == [closed])
        #expect(window.tabIDs == [closed, survivor])
        #expect(window.selectedTabID == survivor)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func partialRestoreDropsMissingMembersAndDerivesActivationFromNativeSelection() throws {
        let missing = UUID(), survivor = UUID(), unassigned = UUID()
        let lostGroup = UUID(), keptGroup = UUID()
        let saved = TabOrganizationState.Window(
            id: UUID(), groups: [
                .init(id: lostGroup, name: "Missing", tabIDs: [missing], lastSelectedTabID: missing),
                .init(id: keptGroup, name: "Present", tabIDs: [survivor], lastSelectedTabID: survivor)
            ], unassigned: [unassigned], selectedTabID: missing, activeGroupID: lostGroup)
        var restored = Model.retaining(saved, tabs: [survivor, unassigned], order: nil)
        Model.select(survivor, in: &restored)
        #expect(restored.groups.map(\.id) == [keptGroup])
        #expect(restored.tabIDs == [survivor, unassigned])
        #expect(restored.selectedTabID == survivor)
        #expect(restored.activeGroupID == keptGroup)
        try TabOrganizationState(windows: [restored]).validate()
    }

    @Test func failedNativeReorderDoesNotPublishFictitiousContiguousGroups() throws {
        let a = UUID(), b = UUID(), c = UUID(), trailing = UUID()
        let first = UUID(), second = UUID()
        let saved = TabOrganizationState.Window(
            id: UUID(), groups: [
                .init(id: first, name: "First", tabIDs: [a, b], lastSelectedTabID: b),
                .init(id: second, name: "Second", tabIDs: [c], lastSelectedTabID: c)
            ], unassigned: [trailing], selectedTabID: b, activeGroupID: first)
        let nativeOrder = [a, c, b, trailing]
        let reconciled = Model.nativeFallback(saved, order: nativeOrder)
        #expect(reconciled.tabIDs == nativeOrder)
        #expect(reconciled.groups.isEmpty)
        #expect(reconciled.selectedTabID == b)
        #expect(reconciled.activeGroupID == nil)
        try TabOrganizationState(windows: [reconciled]).validate()
    }

    @Test func versionSevenIdentityEnvelopeSurvivesTheNativeCopyDecoder() throws {
        let identity = TabOrganizationIdentity(tabID: UUID(), windowID: UUID())
        var fixture = try nativeFixture()
        fixture["organizationIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        let state = try JSONDecoder().decode(TerminalRestorableState.self, from: JSONSerialization.data(withJSONObject: fixture))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        #expect(unarchiver.decodeInteger(forKey: TerminalRestorableState.versionKey) == 7)
        let restored = try #require(TerminalRestorableState(coder: unarchiver))
        #expect(restored.organizationIdentity == identity)
        #expect(restored.titleOverride == "Retained native title")
    }

    @Test func legacyAndDamagedOrganizationEnvelopesDoNotRejectNativeState() throws {
        let fixture = try nativeFixture()
        let legacy = try JSONDecoder().decode(TerminalRestorableState.self, from: JSONSerialization.data(withJSONObject: fixture))
        #expect(legacy.organizationIdentity == nil)
        #expect(legacy.titleOverride == "Retained native title")
        var damagedFixture = fixture
        damagedFixture["organizationIdentity"] = ["tabID": "invalid", "windowID": UUID().uuidString]
        let damaged = try JSONDecoder().decode(TerminalRestorableState.self, from: JSONSerialization.data(withJSONObject: damagedFixture))
        #expect(damaged.organizationIdentity == nil)
        #expect(damaged.titleOverride == legacy.titleOverride)
        #expect(damaged.tabColor == .blue)
    }

    @Test func batchUndoRetainsSavedMemberAndGroupOrder() throws {
        let tabs = (0..<4).map { _ in UUID() }
        let owner = UUID()
        let nativeOrder = [tabs[0], tabs[3], tabs[2], tabs[1]]
        let group = TabOrganizationState.Group(id: UUID(), name: "Project", tabIDs: tabs, lastSelectedTabID: tabs[0])
        let members = tabs.enumerated().map { index, id in
            TabOrganization.UndoContext(identity: .init(tabID: id, windowID: owner),
                                        group: group, groupIndex: 0, tabIndex: index)
        }
        var window = TabOrganizationState.Window(id: owner, groups: [], unassigned: nativeOrder,
                                                 selectedTabID: tabs[0], activeGroupID: nil)
        Model.restore([members[0], members[3], members[2], members[1]], in: &window)
        #expect(window.groups.map(\.id) == [group.id])
        #expect(window.tabIDs == tabs)
        try TabOrganizationState(windows: [window]).validate()

        let groups = tabs.enumerated().map { index, id in
            TabOrganization.UndoContext(identity: .init(tabID: id, windowID: owner),
                                        group: .init(id: UUID(), name: "Project", tabIDs: [id], lastSelectedTabID: id),
                                        groupIndex: index, tabIndex: 0)
        }
        window = .init(id: owner, groups: [], unassigned: nativeOrder, selectedTabID: tabs[0], activeGroupID: nil)
        Model.restore([groups[0], groups[3], groups[2], groups[1]], in: &window)
        #expect(window.groups.map(\.id) == groups.compactMap { $0.group?.id })
        #expect(window.tabIDs == tabs)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func inactiveGroupReorderRetainsRememberedSelection() throws {
        let a = UUID(), remembered = UUID(), c = UUID(), selected = UUID(), group = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(),
            groups: [.init(id: group, name: "Project", tabIDs: [a, remembered, c], lastSelectedTabID: remembered)],
            unassigned: [selected], selectedTabID: selected, activeGroupID: nil)
        #expect(Model.move(remembered, to: group, index: 2, in: &window))
        #expect(window.groups[0].tabIDs == [a, c, remembered])
        #expect(window.groups[0].lastSelectedTabID == remembered)
        #expect(window.selectedTabID == selected)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    private func nativeFixture() throws -> [String: Any] {
        // Empty trees exercise the native Codable envelope without launching any terminal.
        let tree = try JSONEncoder().encode(SplitTree<Ghostty.SurfaceView>())
        return [
            "surfaceTree": try JSONSerialization.jsonObject(with: tree),
            "tabColor": TerminalTabColor.blue.rawValue,
            "titleOverride": "Retained native title"
        ]
    }
}
