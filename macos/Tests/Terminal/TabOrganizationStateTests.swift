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

    @Test func preColorSnapshotRetainsItsFullOrganization() throws {
        let windowIDs = [UUID(), UUID()]
        let groupIDs = [UUID(), UUID()]
        let tabs = (0..<8).map { _ in UUID() }
        let expected = TabOrganizationState(windows: [
            .init(id: windowIDs[0], groups: [
                .init(id: groupIDs[0], name: "Build", tabIDs: [tabs[1], tabs[0]], lastSelectedTabID: tabs[0]),
                .init(id: groupIDs[1], name: "Run", tabIDs: [tabs[3], tabs[2]], lastSelectedTabID: tabs[3])
            ], unassigned: [tabs[5], tabs[4]], selectedTabID: tabs[3], activeGroupID: groupIDs[1]),
            .init(id: windowIDs[1], unassigned: [tabs[7], tabs[6]], selectedTabID: tabs[6])
        ])
        let original = Data("""
        {
          "version": 1,
          "windows": [
            {
              "id": "\(windowIDs[0])",
              "groups": [
                {
                  "id": "\(groupIDs[0])", "name": "Build",
                  "tabIDs": ["\(tabs[1])", "\(tabs[0])"], "lastSelectedTabID": "\(tabs[0])"
                },
                {
                  "id": "\(groupIDs[1])", "name": "Run",
                  "tabIDs": ["\(tabs[3])", "\(tabs[2])"], "lastSelectedTabID": "\(tabs[3])"
                }
              ],
              "unassigned": ["\(tabs[5])", "\(tabs[4])"],
              "selectedTabID": "\(tabs[3])", "activeGroupID": "\(groupIDs[1])"
            },
            {
              "id": "\(windowIDs[1])", "groups": [],
              "unassigned": ["\(tabs[7])", "\(tabs[6])"], "selectedTabID": "\(tabs[6])"
            }
          ]
        }
        """.utf8)
        let suite = "GhosttyTabOrganizationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original, forKey: TabOrganizationStore.key)

        let restored = try #require(try TabOrganizationStore(defaults: defaults).load())
        #expect(restored == expected)
        #expect(restored.windows[0].groups.map(\.color) == [.none, .none])
        #expect(defaults.data(forKey: TabOrganizationStore.key) == original)
    }

    @Test(arguments: ["null", "999", "\"blue\""])
    func invalidPresentGroupColorIsPreservedForRecovery(_ encodedColor: String) throws {
        var envelope = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        var windows = try #require(envelope["windows"] as? [[String: Any]])
        var groups = try #require(windows[0]["groups"] as? [[String: Any]])
        groups[0]["color"] = try JSONSerialization.jsonObject(
            with: Data(encodedColor.utf8), options: [.fragmentsAllowed])
        windows[0]["groups"] = groups
        envelope["windows"] = windows
        let original = try JSONSerialization.data(withJSONObject: envelope)
        let suite = "GhosttyTabOrganizationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original, forKey: TabOrganizationStore.key)

        let store = TabOrganizationStore(defaults: defaults)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(throws: TabOrganizationStore.StoreError.self) { try store.save(fixture()) }
        #expect(defaults.data(forKey: TabOrganizationStore.key) == original)

        let validEdit = fixture()
        try store.save(validEdit, explicitEdit: true)
        #expect(try TabOrganizationStore(defaults: defaults).load() == validEdit)
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
                .init(id: firstGroup, name: "Project", tabIDs: [UUID(), selected],
                      lastSelectedTabID: selected, color: .purple),
                .init(id: UUID(), name: "Project", tabIDs: [UUID(), UUID()], color: .green)
            ], unassigned: [UUID()], selectedTabID: selected, activeGroupID: firstGroup)
        ])
    }
}
