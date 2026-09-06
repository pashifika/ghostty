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
                .init(id: first, name: "Work", tabIDs: [a], lastSelectedTabID: a, color: .red),
                .init(id: second, name: "Work", tabIDs: [b, c], lastSelectedTabID: c, color: .green)
            ],
            unassigned: [unassigned], selectedTabID: c, activeGroupID: second)

        #expect(Model.move(a, to: second, index: 1, in: &window))
        #expect(window.groups.map(\.id) == [second])
        #expect(window.groups[0].tabIDs == [b, a, c])
        #expect(window.groups[0].color == .green)
        #expect(window.selectedTabID == c)
        #expect(window.activeGroupID == second)

        #expect(Model.move(c, to: nil, index: 0, in: &window))
        #expect(window.unassigned == [c, unassigned])
        #expect(window.selectedTabID == c)
        #expect(window.activeGroupID == nil)
        #expect(window.groups[0].color == .green)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func reorderingWithinTheOnlyMemberGroupKeepsItsIdentity() throws {
        let tab = UUID(), groupID = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(), groups: [.init(id: groupID, name: "Only", tabIDs: [tab], lastSelectedTabID: tab, color: .pink)],
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
                .init(id: removed, name: "Delete", tabIDs: [a, b], lastSelectedTabID: b, color: .orange),
                .init(id: retained, name: "Keep", tabIDs: [other], lastSelectedTabID: other, color: .teal)
            ],
            unassigned: [trailing], selectedTabID: b, activeGroupID: removed)
        #expect(Model.dissolve(removed, in: &window))
        #expect(window.groups.map(\.id) == [retained])
        #expect(window.groups[0].color == .teal)
        #expect(window.tabIDs == [other, trailing, a, b])
        #expect(window.selectedTabID == b)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func undoRecreatesARemovedLastMemberGroupWithoutDuplicatingTabs() throws {
        let closed = UUID(), survivor = UUID(), groupID = UUID(), windowID = UUID()
        let group = TabOrganizationState.Group(
            id: groupID, name: "Return", tabIDs: [closed], lastSelectedTabID: closed, color: .purple)
        var window = TabOrganizationState.Window(
            id: windowID, groups: [group], unassigned: [survivor], selectedTabID: closed, activeGroupID: groupID)
        let context = TabOrganization.UndoContext(
            identity: .init(tabID: closed, windowID: windowID), group: group, groupIndex: 0, tabIndex: 0)
        Model.remove(closed, from: &window)
        Model.select(survivor, in: &window)
        #expect(window.groups.isEmpty)
        let native = try restoredNativeFixture(identity: context.identity)
        let returned = try #require(native.organizationIdentity)

        // The native Undo path has returned exactly this tab. Applying its context twice
        // must still leave one member, not clone the old group or its terminal identity.
        window.unassigned.append(returned.tabID)
        Model.restore(returned.tabID, context: context, in: &window)
        Model.restore(returned.tabID, context: context, in: &window)
        #expect(window.groups == [group])
        #expect(native.tabColor == .blue)
        #expect(window.tabIDs == [closed, survivor])
        #expect(window.selectedTabID == survivor)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func undoRetainsASurvivingGroupsNewerColorAndIndependentTabColor() throws {
        let closed = UUID(), survivor = UUID(), selected = UUID(), groupID = UUID(), windowID = UUID()
        let group = TabOrganizationState.Group(
            id: groupID, name: "Project", tabIDs: [closed, survivor], lastSelectedTabID: survivor, color: .red)
        var window = TabOrganizationState.Window(
            id: windowID, groups: [group], unassigned: [selected], selectedTabID: selected)
        let context = TabOrganization.UndoContext(
            identity: .init(tabID: closed, windowID: windowID), group: group, groupIndex: 0, tabIndex: 0)
        Model.remove(closed, from: &window)
        window.groups[0].color = .green

        let native = try restoredNativeFixture(identity: context.identity)
        let returned = try #require(native.organizationIdentity)
        window.unassigned.append(returned.tabID)
        Model.restore(returned.tabID, context: context, in: &window)
        var expectedGroup = group
        expectedGroup.color = .green
        #expect(window.groups == [expectedGroup])
        #expect(window.unassigned == [selected])
        #expect(window.selectedTabID == selected)
        #expect(window.activeGroupID == nil)
        #expect(native.tabColor == .blue)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func repeatedUndoRetainsASoleMembersCurrentGroupMetadataAndPosition() throws {
        let tab = UUID(), selected = UUID(), windowID = UUID()
        let original = TabOrganizationState.Group(
            id: UUID(), name: "Original", tabIDs: [tab], lastSelectedTabID: tab, color: .red)
        let context = TabOrganization.UndoContext(
            identity: .init(tabID: tab, windowID: windowID), group: original, groupIndex: 0, tabIndex: 0)
        var current = original
        current.name = "Renamed"
        current.color = .green
        let other = TabOrganizationState.Group(
            id: UUID(), name: "Other", tabIDs: [selected], lastSelectedTabID: selected, color: .orange)
        var window = TabOrganizationState.Window(
            id: windowID, groups: [other, current], selectedTabID: selected, activeGroupID: other.id)
        let before = window

        Model.restore(tab, context: context, in: &window)
        #expect(window == before)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func partialRestoreDropsMissingMembersAndDerivesActivationFromNativeSelection() throws {
        let missing = UUID(), survivor = UUID(), unassigned = UUID()
        let lostGroup = UUID(), keptGroup = UUID()
        let saved = TabOrganizationState.Window(
            id: UUID(), groups: [
                .init(id: lostGroup, name: "Missing", tabIDs: [missing], lastSelectedTabID: missing, color: .red),
                .init(id: keptGroup, name: "Present", tabIDs: [survivor], lastSelectedTabID: survivor, color: .teal)
            ], unassigned: [unassigned], selectedTabID: missing, activeGroupID: lostGroup)
        var restored = Model.retaining(saved, tabs: [survivor, unassigned], order: nil)
        Model.select(survivor, in: &restored)
        #expect(restored.groups.map(\.id) == [keptGroup])
        #expect(restored.groups[0].color == .teal)
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
        let restored = try restoredNativeFixture(identity: identity)
        #expect(restored.organizationIdentity == identity)
        #expect(restored.titleOverride == "Retained native title")
        #expect(restored.tabColor == .blue)
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
        let group = TabOrganizationState.Group(
            id: UUID(), name: "Project", tabIDs: tabs, lastSelectedTabID: tabs[0], color: .purple)
        let members = tabs.enumerated().map { index, id in
            TabOrganization.UndoContext(identity: .init(tabID: id, windowID: owner),
                                        group: group, groupIndex: 0, tabIndex: index)
        }
        var window = TabOrganizationState.Window(id: owner, groups: [], unassigned: nativeOrder,
                                                 selectedTabID: tabs[0], activeGroupID: nil)
        Model.restore([members[0], members[3], members[2], members[1]], in: &window)
        #expect(window.groups == [group])
        #expect(window.tabIDs == tabs)
        try TabOrganizationState(windows: [window]).validate()

        let colors: [TerminalTabColor] = [.red, .green, .orange, .none]
        let groups = tabs.enumerated().map { index, id in
            TabOrganization.UndoContext(identity: .init(tabID: id, windowID: owner),
                                        group: .init(id: UUID(), name: "Project", tabIDs: [id],
                                                     lastSelectedTabID: id, color: colors[index]),
                                        groupIndex: index, tabIndex: 0)
        }
        window = .init(id: owner, groups: [], unassigned: nativeOrder, selectedTabID: tabs[0], activeGroupID: nil)
        Model.restore([groups[0], groups[3], groups[2], groups[1]], in: &window)
        #expect(window.groups.map(\.id) == groups.compactMap { $0.group?.id })
        #expect(window.groups.map(\.color) == colors)
        #expect(window.tabIDs == tabs)
        try TabOrganizationState(windows: [window]).validate()
    }

    @Test func inactiveGroupReorderRetainsRememberedSelection() throws {
        let a = UUID(), remembered = UUID(), c = UUID(), selected = UUID(), group = UUID()
        var window = TabOrganizationState.Window(
            id: UUID(),
            groups: [.init(id: group, name: "Project", tabIDs: [a, remembered, c],
                           lastSelectedTabID: remembered, color: .yellow)],
            unassigned: [selected], selectedTabID: selected, activeGroupID: nil)
        #expect(Model.move(remembered, to: group, index: 2, in: &window))
        #expect(window.groups[0].tabIDs == [a, c, remembered])
        #expect(window.groups[0].lastSelectedTabID == remembered)
        #expect(window.groups[0].color == .yellow)
        #expect(window.selectedTabID == selected)
        #expect(window.activeGroupID == nil)
        try TabOrganizationState(windows: [window]).validate()
    }

    private func restoredNativeFixture(identity: TabOrganizationIdentity) throws -> TerminalRestorableState {
        var fixture = try nativeFixture()
        fixture["organizationIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        let state = try JSONDecoder().decode(TerminalRestorableState.self, from: JSONSerialization.data(withJSONObject: fixture))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        #expect(unarchiver.decodeInteger(forKey: TerminalRestorableState.versionKey) == 7)
        return try #require(TerminalRestorableState(coder: unarchiver))
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
