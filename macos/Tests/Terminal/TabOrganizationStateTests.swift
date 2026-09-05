import Foundation
import Testing
@testable import Ghostty

@Suite
struct TabOrganizationStateTests {
    @Test func duplicateMembershipAcrossNativeWindowsIsRejected() throws {
        var state = fixture()
        let member = try #require(state.windows.first?.groups.first?.tabIDs.first)
        state.windows.append(.init(id: UUID(), unassigned: [member], selectedTabID: member))
        #expect(throws: TabOrganizationState.ValidationError.self) { try state.validate() }
    }

    @Test func activeGroupCannotDisagreeWithSelectedTerminal() throws {
        var state = fixture()
        state.windows[0].selectedTabID = try #require(state.windows[0].unassigned.first)
        #expect(throws: TabOrganizationState.ValidationError.self) { try state.validate() }
    }

    @Test func invalidStoredDataSurvivesUntilAnExplicitValidEdit() throws {
        let suite = "GhosttyTabOrganizationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data(#"{"version":99,"windows":[],"futureField":"keep for recovery"}"#.utf8)
        defaults.set(original, forKey: TabOrganizationStore.key)
        let store = TabOrganizationStore(defaults: defaults)
        #expect(throws: TabOrganizationState.ValidationError.self) { try store.load() }
        #expect(throws: TabOrganizationStore.StoreError.self) { try store.save(fixture()) }
        #expect(defaults.data(forKey: TabOrganizationStore.key) == original)

        var invalidEdit = fixture()
        invalidEdit.windows[0].groups[0].tabIDs = []
        #expect(throws: TabOrganizationState.ValidationError.self) {
            try store.save(invalidEdit, explicitEdit: true)
        }
        #expect(defaults.data(forKey: TabOrganizationStore.key) == original)
        #expect(throws: TabOrganizationStore.StoreError.self) { try store.save(fixture()) }

        let validEdit = fixture()
        try store.save(validEdit, explicitEdit: true)
        let reopened = TabOrganizationStore(defaults: defaults)
        #expect(try reopened.load() == validEdit)
    }

    private func fixture() -> TabOrganizationState {
        let selected = UUID()
        let firstGroup = UUID()
        return TabOrganizationState(windows: [
            .init(id: UUID(), groups: [
                .init(id: firstGroup, name: "Project", tabIDs: [selected], lastSelectedTabID: selected),
                .init(id: UUID(), name: "Project", tabIDs: [UUID()])
            ], unassigned: [UUID()], selectedTabID: selected, activeGroupID: firstGroup)
        ])
    }
}
