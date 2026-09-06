#if os(macOS)
import Foundation

/// Additive native-restoration metadata, independent of any terminal split.
struct TabOrganizationIdentity: Codable, Equatable {
    var tabID: UUID
    var windowID: UUID
}

/// Organization metadata only. Native restoration owns terminal construction.
struct TabOrganizationState: Codable, Equatable {
    var version = 1
    var windows: [Window] = []

    struct Window: Codable, Equatable {
        var id: UUID
        var groups: [Group] = []
        var unassigned: [UUID] = []
        var selectedTabID: UUID?
        var activeGroupID: UUID?

        var tabIDs: [UUID] { groups.flatMap(\.tabIDs) + unassigned }
    }

    struct Group: Codable, Equatable {
        var id: UUID
        var name: String
        var tabIDs: [UUID]
        var lastSelectedTabID: UUID?
        var color: TerminalTabColor = .none

        init(
            id: UUID,
            name: String,
            tabIDs: [UUID],
            lastSelectedTabID: UUID? = nil,
            color: TerminalTabColor = .none
        ) {
            self.id = id
            self.name = name
            self.tabIDs = tabIDs
            self.lastSelectedTabID = lastSelectedTabID
            self.color = color
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, tabIDs, lastSelectedTabID, color
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            tabIDs = try values.decode([UUID].self, forKey: .tabIDs)
            lastSelectedTabID = try values.decodeIfPresent(UUID.self, forKey: .lastSelectedTabID)
            // Only pre-color snapshots omit this key; null and malformed values remain invalid.
            if values.contains(.color) {
                color = try values.decode(TerminalTabColor.self, forKey: .color)
            } else {
                color = .none
            }
        }
    }

    enum ValidationError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case invalidPartition
        case invalidSelection

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Unsupported tab organization state version: \(version)."
            case .invalidPartition:
                return "Tab organization state contains duplicate identities, an empty group, or an invalid name."
            case .invalidSelection:
                return "Tab organization state contains an invalid active group or selected tab."
            }
        }
    }

    func validate() throws {
        guard version == 1 else { throw ValidationError.unsupportedVersion(version) }
        var windowIDs = Set<UUID>()
        var groupIDs = Set<UUID>()
        var tabIDs = Set<UUID>()
        for window in windows {
            guard windowIDs.insert(window.id).inserted else { throw ValidationError.invalidPartition }
            var members = Set<UUID>()
            for group in window.groups {
                guard groupIDs.insert(group.id).inserted,
                      !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !group.tabIDs.isEmpty else { throw ValidationError.invalidPartition }
                for tabID in group.tabIDs {
                    guard tabIDs.insert(tabID).inserted else { throw ValidationError.invalidPartition }
                    members.insert(tabID)
                }
                if let selected = group.lastSelectedTabID, !group.tabIDs.contains(selected) {
                    throw ValidationError.invalidSelection
                }
            }
            for tabID in window.unassigned {
                guard tabIDs.insert(tabID).inserted else { throw ValidationError.invalidPartition }
                members.insert(tabID)
            }
            if let active = window.activeGroupID, !window.groups.contains(where: { $0.id == active }) {
                throw ValidationError.invalidSelection
            }
            if let selected = window.selectedTabID {
                guard members.contains(selected),
                      window.groups.first(where: { $0.tabIDs.contains(selected) })?.id == window.activeGroupID else {
                    throw ValidationError.invalidSelection
                }
            }
        }
    }
}

/// Synchronous encoding prevents older work from replacing a newer mutation.
/// UserDefaults and AppKit state are separate OS-managed stores, not a crash-atomic transaction.
final class TabOrganizationStore {
    static let key = "tab-organization-state-v1"
    private let defaults: UserDefaults
    private(set) var hasInvalidState = false

    enum StoreError: Error, LocalizedError {
        case invalidRepresentation
        case retainedInvalidState

        var errorDescription: String? {
            switch self {
            case .invalidRepresentation:
                return "Tab organization state is not encoded data; the original value has been retained."
            case .retainedInvalidState:
                return "Invalid tab organization state is retained until an explicit organization edit replaces it."
            }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() throws -> TabOrganizationState? {
        guard let value = defaults.object(forKey: Self.key) else {
            hasInvalidState = false
            return nil
        }
        do {
            guard let data = value as? Data else { throw StoreError.invalidRepresentation }
            let state = try JSONDecoder().decode(TabOrganizationState.self, from: data)
            try state.validate()
            hasInvalidState = false
            return state
        } catch {
            hasInvalidState = true
            throw error
        }
    }

    /// Requests persistence; this does not promise a durable cross-store checkpoint.
    func save(_ state: TabOrganizationState, explicitEdit: Bool = false) throws {
        guard !hasInvalidState || explicitEdit else { throw StoreError.retainedInvalidState }
        try state.validate()
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: Self.key)
        hasInvalidState = false
    }
}
#endif
