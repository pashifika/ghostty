import AppKit
import Foundation

// Standalone executable; intentionally outside the app and XCTest source roots.
// Build the DEBUG app with a fresh dev.pashifika.ghostty.organization-probe.<unique> bundle ID.
// Run: xcrun swift macos/Probes/NativeRestorationGate.swift /absolute/Ghostty.app /new/evidence-directory [native|groups|groups-partial|groups-never|groups-precolor]
// No ApplePersistenceIgnoreState, fixture decoding, forced termination, or timed restore barrier.
// The deadline only fails a stalled run. All success conditions come from native events.

private var bundleID = ""
private let fileManager = FileManager.default
private let timeout: TimeInterval = 60
private let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "native"
private var grouped: Bool { mode != "native" }
private var currentApplication: NSRunningApplication?
private var currentPhase: String?
private var exits: [String: [String: Any]] = [:]
private var evidenceDirectory: URL?
private var runID = UUID().uuidString
private var report: [String: Any] = [
    "status": "failed", "gate": "native-restoration-feasibility", "featureComplete": false,
    "barrier": "NSApplication.didFinishRestoringWindowsNotification",
    "barrierContract": "Xcode 26.2 AppKit NSWindowRestoration.h:48-50: all native completion handlers called; posted even for zero windows; may precede or follow didFinishLaunching",
    "responderContract": "Every actual native callback and restore/focus body must return; controller/first-responder agreement and fresh child PWD handshakes are observed after normal main-loop propagation, without waiting for saved membership or selection",
    "observationBoundary": "main-queue delivery followed by CFRunLoop.beforeWaiting",
    "scope": "Isolated native or grouped restart verification; the selected mode and actual checks delimit the proof",
    "documentation": "https://developer.apple.com/documentation/appkit/nsapplication/didfinishrestoringwindowsnotification"
]

private struct GateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw GateFailure(message) }
}

private func waitUntil(_ reason: String, _ predicate: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try !predicate() {
        if Date() >= deadline { throw GateFailure("Timed out (not a completion barrier): " + reason) }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

private func records(_ phase: String) throws -> [[String: Any]] {
    guard let root = evidenceDirectory else { return [] }
    let url = root.appendingPathComponent(phase + ".jsonl")
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    // Only consume newline-terminated records; the last write may still be in flight.
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
    return try lines.map { line in
        guard let value = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw GateFailure("Invalid probe record")
        }
        try require(value["run"] as? String == runID && value["phase"] as? String == phase, "Unrelated probe evidence")
        return value
    }
}

private func event(_ name: String, phase: String, checkingFailures: Bool = true) throws -> [String: Any] {
    var found: [String: Any]?
    try waitUntil(name + " in " + phase) {
        let events = try records(phase)
        if checkingFailures, let failure = events.first(where: { $0["event"] as? String == "failure" }) {
            throw GateFailure("Probe failure: " + (failure["reason"] as? String ?? "unknown"))
        }
        found = events.first { $0["event"] as? String == name }
        if found != nil { return true }
        if currentApplication?.isTerminated == true { throw GateFailure("Application exited before " + name) }
        return false
    }
    return found!
}

private func send(_ action: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(bundleID + ".restore-command"), object: runID,
        userInfo: ["action": action], deliverImmediately: true)
}

private func launch(_ appURL: URL, root: URL, phase: String) throws {
    currentPhase = phase
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GHOSTTY_") }
    environment["GHOSTTY_ORGANIZATION_PROBE"] = "restore"
    environment["GHOSTTY_ORGANIZATION_PROBE_DIRECTORY"] = root.path
    environment["GHOSTTY_ORGANIZATION_PROBE_RUN"] = runID
    environment["GHOSTTY_ORGANIZATION_PROBE_PHASE"] = phase
    environment["GHOSTTY_USER_DEFAULTS_SUITE"] = bundleID + "." + runID
    environment["GHOSTTY_CONFIG_PATH"] = root.appendingPathComponent("config").path
    environment["GHOSTTY_ORGANIZATION_PROBE_MODE"] = mode
    // The controlled shell never reads the user's interactive startup files.
    environment["ENV"] = ""
    environment["BASH_ENV"] = ""
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.environment = environment
    configuration.arguments = []
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.addsToRecentItems = false
    var finished = false
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        DispatchQueue.main.async {
            if let app, app.bundleIdentifier != bundleID {
                report["unrelatedLaunch"] = ["pid": Int(app.processIdentifier), "bundleID": app.bundleIdentifier ?? ""]
                launchError = GateFailure("LaunchServices opened an unrelated bundle; it was not touched")
            } else {
                currentApplication = app
                launchError = error
            }
            finished = true
        }
    }
    try waitUntil("LaunchServices launch") { finished }
    if let launchError { throw launchError }
    try require(currentApplication?.bundleIdentifier == bundleID, "LaunchServices opened the wrong bundle")
    let start = try event("probeStarted", phase: phase)
    try require(start["pid"] as? Int == Int(currentApplication!.processIdentifier), "Probe PID differs from launched application")
    try require(start["ignoreState"] as? Bool == false && start["keepWindows"] as? Bool == true, "Native Resume is disabled")
    try require(start["suite"] as? String == bundleID + "." + runID, "Wrong defaults suite")
    try require(start["config"] as? String == root.appendingPathComponent("config").path, "Wrong config on launch")
}

private func orderlyQuit(_ phase: String, checkingFailures: Bool = true) throws {
    guard let application = currentApplication else { throw GateFailure("No launched probe application to quit") }
    try require(application.bundleIdentifier == bundleID && currentPhase == phase, "Refusing to quit an unrelated application")
    send("quit")
    _ = try event("orderlyQuitRequested", phase: phase, checkingFailures: false)
    let termination = try event("applicationWillTerminate", phase: phase, checkingFailures: false)
    try require(termination["orderlyQuitRequested"] as? Bool == true, "Termination did not use NSApp.terminate")
    try waitUntil("Orderly process exit") { application.isTerminated }
    exits[phase] = ["pid": Int(application.processIdentifier), "terminated": true, "orderly": true]
    currentApplication = nil
    currentPhase = nil
    if checkingFailures {
        let finalEvents = try records(phase)
        try require(!finalEvents.contains { $0["event"] as? String == "failure" }, "Probe reported a failure before or during quit")
        try require(!finalEvents.contains { $0["event"] as? String == "fallbackWindowCreated" }, "A fallback window was created")
    }
}

private func windows(_ observation: [String: Any]) throws -> [[String: Any]] {
    guard let windows = observation["windows"] as? [[String: Any]] else { throw GateFailure("Missing window snapshots") }
    return windows
}

private func surfaces(_ windows: [[String: Any]]) throws -> [[String: Any]] {
    try windows.flatMap { window in
        guard let surfaces = window["surfaces"] as? [[String: Any]] else { throw GateFailure("Missing surface snapshots") }
        return surfaces
    }
}

private func surfaceIDs(_ windows: [[String: Any]]) throws -> [String] {
    try surfaces(windows).map { view in
        guard let id = view["id"] as? String else { throw GateFailure("Missing surface ID") }
        return id
    }
}

private func directories(for phase: String) -> [String] {
    if phase == "restore" && mode == "groups-never" { return [] }
    let values = grouped ? ["a", "b", "c", "d", "e"] : ["a", "b", "c"]
    return phase == "restore" && mode == "groups-partial" ? values.filter { $0 != "c" } : values
}

private func tabCount(for phase: String) -> Int {
    let count = directories(for: phase).count
    return count == 0 ? 0 : count - 1
}

private func assertFixture(_ observation: [String: Any], root: URL) throws {
    let phase = observation["phase"] as? String ?? ""
    let tabs = try windows(observation)
    let leaves = try surfaces(tabs)
    let ids = try surfaceIDs(tabs)
    let expectedDirectories = directories(for: phase)
    let expectedTabs = tabCount(for: phase)
    try require(tabs.count == expectedTabs && leaves.count == expectedDirectories.count &&
                Set(ids).count == leaves.count, "Native tab/surface counts differ from the selected fixture mode")
    if expectedTabs > 0 {
        try require(tabs.map { ($0["surfaces"] as? [Any])?.count ?? 0 }.sorted() ==
                    Array(repeating: 1, count: expectedTabs - 1) + [2], "Fixture split topology is missing")
    }
    try require(observation["createdSurfaces"] as? Int == leaves.count, "Actual C surface creation count differs from fixture")
    try require(leaves.allSatisfy { $0["live"] as? Bool == true && $0["attached"] as? Bool == true }, "A surface has no live native view")
    let expectedPWDs = Set(expectedDirectories.map { root.appendingPathComponent($0).path })
    try require(Set(leaves.compactMap { $0["pwd"] as? String }) == expectedPWDs, "Actual terminal PWDs differ from the fixture")
    let tabIDs = Set(tabs.compactMap { $0["identity"] as? String })
    for tab in tabs {
        let order = tab["tabOrder"] as? [String] ?? []
        try require(order.count == expectedTabs && Set(order) == tabIDs, "Windows are not members of the same native tab group")
        try require(tab["restorationClass"] as? String == "TerminalWindowRestoration", "Fixture has a different restoration owner")
        if !(phase == "seed" && mode == "groups-partial") {
            try require(tab["restorable"] as? Bool == true, "Fixture unexpectedly lost native restoration eligibility")
        }
        try require(tab["focusedSurface"] as? String != "", "Fixture has no focused surface")
    }
    if phase == "seed" && mode == "groups-partial" {
        try require(tabs.filter { $0["restorable"] as? Bool == false }.count == 1, "Partial fixture must omit exactly one real native member")
    }
}

private func assertOrganizationFixture(_ observation: [String: Any], root: URL) throws {
    guard grouped else { return }
    let tabs = try windows(observation)
    let identities = Set(tabs.compactMap { $0["organizationTabID"] as? String })
    try require(identities.count == 4, "Grouped fixture does not have four unique per-tab identities")
    func tabID(in directory: String) throws -> String {
        let pwd = root.appendingPathComponent(directory).path
        guard let tab = tabs.first(where: { tab in
            (tab["surfaces"] as? [[String: Any]] ?? []).contains { $0["pwd"] as? String == pwd }
        }), let id = tab["organizationTabID"] as? String else { throw GateFailure("Missing organization fixture tab") }
        return id
    }
    let first = try tabID(in: "a")
    let second = try tabID(in: "c")
    let third = try tabID(in: "d")
    let fourth = try tabID(in: "e")
    for tab in tabs {
        guard let organization = tab["organization"] as? [String: Any],
              let groups = organization["groups"] as? [[String: Any]] else {
            throw GateFailure("Missing seeded organization presentation")
        }
        try require(groups.count == 2 && Set(groups.compactMap { $0["id"] as? String }).count == 2 &&
                    groups.allSatisfy { $0["name"] as? String == "Project" }, "Equal-named groups were not kept distinct")
        try require(groups[0]["color"] as? Int == 4 && groups[1]["color"] as? Int == 1,
                    "Group colors did not follow the reordered group identities")
        let expectedTabColor = tab["organizationTabID"] as? String == first ? 7 :
            (tab["organizationTabID"] as? String == third ? 2 : 0)
        try require(tab["tabColor"] as? Int == expectedTabColor, "Group coloring changed independent tab colors")
        try require(groups[0]["tabs"] as? [String] == [third] &&
                    groups[1]["tabs"] as? [String] == [second, first] &&
                    organization["unassigned"] as? [String] == [fourth], "Semantic group/member reordering was not committed")
        try require(organization["selectedTabID"] as? String == first &&
                    organization["activeGroupID"] as? String == groups[1]["id"] as? String,
                    "Grouped fixture selection/activation is incoherent")
        let nativeOrder = (tab["tabOrder"] as? [String] ?? []).compactMap { nativeID in
            tabs.first { $0["identity"] as? String == nativeID }?["organizationTabID"] as? String
        }
        try require(nativeOrder == [third, second, first, fourth], "Native order disagrees with committed organization")
    }
}

private func canonical(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func expectedRestoredTabs(_ seeded: [[String: Any]]) -> [[String: Any]] {
    if mode == "groups-never" { return [] }
    return mode == "groups-partial" ? seeded.filter { $0["restorable"] as? Bool == true } : seeded
}

private func survivingOrganization(_ value: [String: Any], tabIDs: Set<String>, memberKey: String) throws -> [String: Any] {
    var result = value
    guard let groups = value["groups"] as? [[String: Any]], let unassigned = value["unassigned"] as? [String] else {
        throw GateFailure("Missing organization partition")
    }
    result["groups"] = try groups.compactMap { group -> [String: Any]? in
        guard let members = group[memberKey] as? [String] else { throw GateFailure("Missing group membership") }
        let surviving = members.filter { tabIDs.contains($0) }
        guard !surviving.isEmpty else { return nil }
        var retained = group
        if mode == "groups-precolor" { retained["color"] = 0 }
        retained[memberKey] = surviving
        if let selected = retained["lastSelectedTabID"] as? String, !tabIDs.contains(selected) {
            retained.removeValue(forKey: "lastSelectedTabID")
        }
        return retained
    }
    result["unassigned"] = unassigned.filter { tabIDs.contains($0) }
    return result
}

private func compareOrganizationStore(seed: [String: Any], restored: [String: Any]) throws {
    guard grouped else { return }
    guard var expected = (report["staleOrganizationSnapshot"] ?? seed["organizationStore"]) as? [String: Any],
          let actual = restored["organizationStore"] as? [String: Any] else {
        throw GateFailure("Organization metadata was not persisted")
    }
    if mode == "groups-partial" || mode == "groups-precolor" {
        let tabs = try windows(restored)
        let surviving = Set(tabs.compactMap { $0["organizationTabID"] as? String })
        guard let savedWindows = expected["windows"] as? [[String: Any]] else { throw GateFailure("Missing stored windows") }
        expected["windows"] = try savedWindows.map {
            try survivingOrganization($0, tabIDs: surviving, memberKey: "tabIDs")
        }
    }
    try require(try canonical(expected) == canonical(actual),
                mode == "groups-never" ? "Disabled restoration changed retained organization data" : "Persisted organization differs after native reconciliation")
}

private func compareRoundTrip(seed: [String: Any], restored: [String: Any], evidenceKey: String = "roundTripDifferences") throws {
    let before = expectedRestoredTabs(try windows(seed))
    let after = try windows(restored)
    let beforeIDs = try surfaceIDs(before)
    let afterIDs = try surfaceIDs(after)
    try require(Set(beforeIDs) == Set(afterIDs), "Restoration did not retain the saved surface identities")
    var differences: [[String: Any]] = []
    let survivingNativeIDs = Set(before.compactMap { $0["identity"] as? String })
    let survivingTabIDs = Set(before.compactMap { $0["organizationTabID"] as? String })
    for saved in before {
        let identity = saved["identity"] as? String
        guard let live = after.first(where: { $0["identity"] as? String == identity }) else {
            throw GateFailure("Missing restored native tab")
        }
        // Window numbers and process IDs intentionally change. Compare live native
        // tab order/selection, split direction/ratio/UUIDs, focused leaf and PWDs.
        for key in ["tabOrder", "selectedTab", "focusedSurface", "tree", "surfaces", "tabColor"] {
            guard var old = saved[key], let new = live[key] else { throw GateFailure("Missing " + key) }
            if key == "tabOrder", let order = old as? [String] {
                old = order.filter { survivingNativeIDs.contains($0) }
            }
            if try canonical([old]) != canonical([new]) {
                differences.append(["identity": identity ?? "", "field": key, "saved": old, "observed": new])
            }
        }
        if live["identity"] as? String == live["selectedTab"] as? String {
            if live["firstResponder"] as? String != saved["focusedSurface"] as? String {
                differences.append([
                    "identity": identity ?? "", "field": "firstResponder",
                    "saved": saved["focusedSurface"] ?? "", "observed": live["firstResponder"] ?? ""
                ])
            }
        }
        if grouped {
            guard let savedOrganization = saved["organization"] as? [String: Any],
                  let liveOrganization = live["organization"] as? [String: Any] else {
                throw GateFailure("Missing live organization presentation")
            }
            let expected = try survivingOrganization(savedOrganization, tabIDs: survivingTabIDs, memberKey: "tabs")
            for key in ["organizationTabID", "organizationWindowID"] {
                try require(saved[key] as? String == live[key] as? String, "Stable native organization identity changed")
            }
            if try canonical(expected) != canonical(liveOrganization) {
                differences.append(["identity": identity ?? "", "field": "organization",
                                    "saved": expected, "observed": liveOrganization])
            }
        }
    }
    report[evidenceKey] = differences
    try require(differences.isEmpty, "Round trip changed " + differences.compactMap { $0["field"] as? String }.joined(separator: ", "))
}

private func sessionEvidence(_ phase: String, root: URL) throws -> [[String: Any]] {
    let directory = root.appendingPathComponent("sessions/" + phase)
    let paths = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try paths.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { path in
        let fields = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
        try require(fields.count == 5, "Incomplete child-session handshake")
        try require(fields[0] == runID && fields[1] == phase && Int(fields[2]) != nil &&
                    UUID(uuidString: fields[3]) != nil && fields[3] == path.lastPathComponent &&
                    fields[4].hasPrefix("/"), "Invalid child-session handshake")
        return ["run": fields[0], "phase": fields[1], "pid": Int(fields[2])!, "nonce": fields[3], "pwd": fields[4]]
    }
}

private func assertSessions(_ observation: [String: Any], files: [[String: Any]]) throws {
    let leaves = try surfaces(windows(observation))
    guard let sessions = observation["sessions"] as? [[String: Any]] else { throw GateFailure("Missing surface-session associations") }
    let ids = Set(leaves.compactMap { $0["id"] as? String })
    try require(sessions.count == leaves.count && files.count == sessions.count &&
                Set(sessions.compactMap { $0["surface"] as? String }) == ids, "Child handshakes do not cover actual live surfaces")
    try require(Set(sessions.compactMap { $0["pid"] as? Int }).count == sessions.count &&
                Set(sessions.compactMap { $0["nonce"] as? String }).count == sessions.count, "Child sessions are not distinct")
    for session in sessions {
        guard let file = files.first(where: { $0["nonce"] as? String == session["nonce"] as? String }),
              let leaf = leaves.first(where: { $0["id"] as? String == session["surface"] as? String }) else {
            throw GateFailure("A child handshake has no real surface or file")
        }
        for key in ["run", "phase", "pid", "nonce", "pwd"] {
            try require(try canonical([file[key] ?? NSNull()]) == canonical([session[key] ?? NSNull()]),
                        "Child handshake disagrees with surface association: " + key)
        }
        try require(leaf["pwd"] as? String == session["pwd"] as? String, "Terminal PWD differs from actual child /bin/pwd -P")
        if observation["phase"] as? String == "restore" {
            let decoded = observation["decodedPWDs"] as? [String: String] ?? [:]
            try require(decoded[session["surface"] as? String ?? ""] == session["pwd"] as? String,
                        "Decoded saved PWD differs from actual restored child /bin/pwd -P")
        }
    }
}

private func assertNativeEvidence(seed: [String: Any], restore: [String: Any]) throws {
    let first = try records("seed")
    let second = try records("restore")
    let nativeRequests = second.filter { $0["event"] as? String == "nativeRestoreBegan" }
    let handoffs = second.filter { $0["event"] as? String == "nativeRestoreHandedToAppKit" }
    let completions = second.filter { $0["event"] as? String == "nativeRestoreCompleted" }
    let bodies = second.filter { $0["event"] as? String == "nativeRestoreBodyFinished" }
    let created = second.filter { $0["event"] as? String == "surfaceCreated" }
    let decoded = second.filter { $0["event"] as? String == "surfaceDecoded" }
    let focus = second.filter { $0["event"] as? String == "nativeFocusFinished" }
    let barriers = second.filter { $0["event"] as? String == "nativeRestorationFinished" }
    report["nativeCallbacks"] = nativeRequests.count
    report["actualRestoredSurfaceCreations"] = created.count
    report["nativeDecodedSurfaces"] = decoded.count
    try require(barriers.count == 1, "Missing or duplicate documented app-wide barrier")
    let barrierSequence = barriers[0]["sequence"] as? Int ?? -1
    let observedSequence = restore["sequence"] as? Int ?? -1
    try require(restore["boundary"] as? String == report["observationBoundary"] as? String &&
                (restore["waitingFor"] as? [String])?.isEmpty == true &&
                barrierSequence < observedSequence, "Observation was not after native completion and event propagation")
    // The fixture count is asserted only AFTER the native barrier, never used to
    // decide that AppKit has finished. Disabled native restore may return no windows.
    let expectedTabs = tabCount(for: "restore")
    let expectedSurfaces = directories(for: "restore").count
    try require((mode == "groups-never" || nativeRequests.count == expectedTabs) &&
                handoffs.count == nativeRequests.count && completions.count == nativeRequests.count &&
                bodies.count == nativeRequests.count, "Missing native callback or body returns")
    try require(handoffs.allSatisfy {
        $0["returnedWindow"] as? Bool == (mode != "groups-never") && $0["error"] as? String == "" &&
        ($0["sequence"] as? Int ?? .max) < barrierSequence
    }, "Native handoff failed or followed the documented barrier")
    let requestIDs = Set(nativeRequests.compactMap { $0["request"] as? String })
    for events in [handoffs, completions, bodies] {
        try require(Set(events.compactMap { $0["request"] as? String }) == requestIDs, "Native request tokens do not pair")
        try require(events.allSatisfy { ($0["sequence"] as? Int ?? .max) < observedSequence },
                    "Observation preceded a native callback or focus-body return")
    }
    for request in nativeRequests {
        let token = request["request"] as? String
        let entered = handoffs.first { $0["request"] as? String == token }?["sequence"] as? Int ?? -1
        let returned = completions.first { $0["request"] as? String == token }?["sequence"] as? Int ?? -1
        let body = bodies.first { $0["request"] as? String == token }?["sequence"] as? Int ?? -1
        try require((request["sequence"] as? Int ?? .max) < entered && entered < returned && returned < body,
                    "Native callback/body ordering is inconsistent")
    }
    try require(created.count == expectedSurfaces && decoded.count == expectedSurfaces,
                "Cached frame-only restoration or duplicate/missing live surfaces")
    let ids = Set(try surfaceIDs(expectedRestoredTabs(windows(seed))))
    try require(Set(created.compactMap { $0["surface"] as? String }) == ids &&
                Set(decoded.compactMap { $0["surface"] as? String }) == ids, "Created surfaces are not the native-decoded fixture")
    try require(focus.count == expectedTabs && focus.allSatisfy {
        $0["succeeded"] as? Bool == true && $0["firstResponderMatches"] as? Bool == true &&
        ($0["sequence"] as? Int ?? .max) < observedSequence
    }, "Native per-window responder restoration did not complete")
    guard let agreements = restore["focusRequests"] as? [[String: Any]] else { throw GateFailure("Missing final per-request focus readback") }
    let restoredRequestIDs = Set(handoffs.filter { $0["returnedWindow"] as? Bool == true }.compactMap { $0["request"] as? String })
    try require(agreements.count == expectedTabs &&
                Set(agreements.compactMap { $0["request"] as? String }) == restoredRequestIDs &&
                agreements.allSatisfy {
                    $0["bodyFinished"] as? Bool == true && ($0["surface"] as? String ?? "") != "" &&
                    $0["firstResponder"] as? String == $0["surface"] as? String &&
                    $0["focusedSurface"] as? String == $0["surface"] as? String
                }, "Controller focus did not agree with the actual native responder request at observation")
    let handshakes = second.filter { $0["event"] as? String == "childSessionObserved" }
    try require(handshakes.count == created.count && handshakes.allSatisfy {
        ($0["sequence"] as? Int ?? .max) < observedSequence
    }, "Observation preceded actual child-session handshakes")
    try require(first.filter { $0["event"] as? String == "surfaceCreated" }.count == directories(for: "seed").count &&
                !first.contains { $0["event"] as? String == "surfaceDecoded" || $0["event"] as? String == "nativeRestoreBegan" }, "First launch was not a clean seed")
    let encoded = first.filter { $0["event"] as? String == "windowEncoded" }
    for tab in try windows(seed) where tab["restorable"] as? Bool == true {
        guard let matching = encoded.last(where: { $0["identity"] as? String == tab["identity"] as? String }) else {
            throw GateFailure("Native encoder did not capture a seeded window")
        }
        for key in ["tree", "surfaces", "focusedSurface", "tabOrder", "selectedTab"] {
            guard let encodedValue = matching[key], let savedValue = tab[key] else {
                throw GateFailure("Missing native encoder field " + key)
            }
            try require(try canonical([encodedValue]) == canonical([savedValue]), "Native encoder captured stale " + key)
        }
    }
    for phase in ["seed", "restore"] {
        for record in try records(phase) where ["didFinishLaunching", "firstActivation"].contains(record["event"] as? String ?? "") {
            let expectedPolicy = phase == "restore" && mode == "groups-never" ? "never" : "always"
            try require(record["initialWindow"] as? Bool == false && record["windowSaveState"] as? String == expectedPolicy &&
                        (record["configErrors"] as? [String])?.isEmpty == true, "Launch configuration/eligibility was not controlled")
        }
    }
}

private func run() throws {
    try require((3...4).contains(CommandLine.arguments.count) &&
                ["native", "groups", "groups-partial", "groups-never", "groups-precolor"].contains(mode),
                "Usage: xcrun swift macos/Probes/NativeRestorationGate.swift /absolute/Ghostty.app /new/evidence-directory [native|groups|groups-partial|groups-never|groups-precolor]")
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
    bundleID = Bundle(url: app)?.bundleIdentifier ?? ""
    let prefix = "dev.pashifika.ghostty.organization-probe."
    try require(bundleID.hasPrefix(prefix) && bundleID.count > prefix.count, "Use a fresh, uniquely suffixed probe bundle for each run")
    try require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty, "A probe app is already running; quit it normally first")
    try require(!fileManager.fileExists(atPath: root.path), "Use a new evidence directory; existing evidence is never overwritten")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    evidenceDirectory = root
    report["run"] = runID
    report["app"] = app.path
    report["bundleID"] = bundleID
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    report["evidenceDirectory"] = root.path
    report["mode"] = mode
    for directory in directories(for: "seed") + ["sessions/seed", "sessions/restore"] {
        try fileManager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    guard let defaults = UserDefaults(suiteName: bundleID) else { throw GateFailure("Cannot open dedicated bundle defaults") }
    try require(defaults.string(forKey: "GhosttyProbeRun") == nil, "Probe bundle was already used; build a new unique bundle ID")
    defaults.set(runID, forKey: "GhosttyProbeRun")
    try require(!defaults.bool(forKey: "ApplePersistenceIgnoreState"), "Dedicated bundle has ApplePersistenceIgnoreState enabled; refusing to suppress or silently change it")
    defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
    try require(defaults.synchronize(), "Could not persist the dedicated bundle's Resume policy before first launch")
    let shell = root.appendingPathComponent("shell.sh")
    let shellSource = """
    #!/bin/sh
    set -eu
    directory="$GHOSTTY_ORGANIZATION_PROBE_DIRECTORY/sessions/$GHOSTTY_ORGANIZATION_PROBE_PHASE"
    nonce=$(/usr/bin/uuidgen)
    actual_pwd=$(/bin/pwd -P)
    /usr/bin/printf '%s\\n%s\\n%s\\n%s\\n%s\\n' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$$" "$nonce" "$actual_pwd" > "$directory/.$nonce"
    /bin/mv "$directory/.$nonce" "$directory/$nonce"
    /usr/bin/printf '\\033]7;file://localhost%s\\007' "$actual_pwd"
    /usr/bin/printf '\\033]2;ghostty-native-session:%s:%s:%s\\007' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$nonce"
    exec /bin/sh -i
    """
    try shellSource.write(to: shell, atomically: true, encoding: .utf8)
    // Quote the command argument for the command parser without executing a
    // historical terminal command. This same current config is used both times.
    let quotedShell = "'" + shell.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let config = """
    window-save-state = always
    initial-window = false
    confirm-close-surface = false
    quit-after-last-window-closed = false
    macos-titlebar-style = \(grouped ? "groups" : "native")
    shell-integration = none
    command = /bin/sh \(quotedShell)
    auto-update = off
    """
    try config.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    report["config"] = config
    report["defaultsSuite"] = bundleID + "." + runID
    try launch(app, root: root, phase: "seed")
    _ = try event("startupObserved", phase: "seed")
    send("seed")
    let seeded = try event("seedReady", phase: "seed")
    report["seed"] = seeded
    try assertFixture(seeded, root: root)
    try assertOrganizationFixture(seeded, root: root)
    let firstSessions = try sessionEvidence("seed", root: root)
    try assertSessions(seeded, files: firstSessions)
    report["sessions"] = ["seed": firstSessions]
    try orderlyQuit("seed")
    if mode == "groups-partial" {
        // Replay only previously emitted organization bytes in the dedicated
        // suite. Native saved state is untouched and still omits the real tab.
        let saved = try event("partialSavedMetadata", phase: "seed")
        guard let key = saved["key"] as? String,
              key == "tab-organization-state-v1",
              let encoded = saved["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedWindows = snapshot["windows"] as? [[String: Any]],
              let isolated = UserDefaults(suiteName: bundleID + "." + runID) else {
            throw GateFailure("Missing genuine pre-omission organization snapshot")
        }
        let storedIDs = storedWindows.flatMap { window -> [String] in
            let groups = window["groups"] as? [[String: Any]] ?? []
            return groups.flatMap { $0["tabIDs"] as? [String] ?? [] } + (window["unassigned"] as? [String] ?? [])
        }
        let seededIDs = try windows(seeded).compactMap { $0["organizationTabID"] as? String }
        try require(storedIDs.count == seededIDs.count && Set(storedIDs) == Set(seededIDs),
                    "Pre-omission metadata must contain every real seeded tab exactly once")
        isolated.set(data, forKey: key)
        try require(isolated.synchronize() && isolated.data(forKey: key) == data,
                    "Could not install the captured stale sidecar in the isolated suite")
        report["staleOrganizationSnapshot"] = snapshot
        report["partialFixtureContract"] = "An actual native-ineligible tab is omitted by AppKit; a genuine earlier organization snapshot still references it. Only isolated metadata bytes are replayed; native terminal state is never decoded or fabricated by the harness."
    }
    if mode == "groups-precolor" {
        guard let isolated = UserDefaults(suiteName: bundleID + "." + runID),
              let data = isolated.data(forKey: "tab-organization-state-v1"),
              var snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var savedWindows = snapshot["windows"] as? [[String: Any]] else {
            throw GateFailure("Missing genuine organization snapshot for pre-color decoding")
        }
        for index in savedWindows.indices {
            guard var groups = savedWindows[index]["groups"] as? [[String: Any]] else {
                throw GateFailure("Missing saved groups")
            }
            for groupIndex in groups.indices { groups[groupIndex].removeValue(forKey: "color") }
            savedWindows[index]["groups"] = groups
        }
        snapshot["windows"] = savedWindows
        let preColor = try canonical(snapshot)
        isolated.set(preColor, forKey: "tab-organization-state-v1")
        try require(isolated.synchronize() && isolated.data(forKey: "tab-organization-state-v1") == preColor,
                    "Could not install pre-color metadata in the isolated suite")
        report["preColorSnapshot"] = snapshot
    }
    if mode == "groups-never" {
        let disabled = config.replacingOccurrences(of: "window-save-state = always", with: "window-save-state = never")
        try disabled.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        report["restoreConfig"] = disabled
    }
    try launch(app, root: root, phase: "restore")
    _ = try event("nativeRestorationFinished", phase: "restore")
    let restored = try event("restoreObserved", phase: "restore")
    report["restore"] = restored
    var checks: [String: [String: Any]] = [:]
    func assess(_ name: String, _ action: () throws -> Void) {
        do {
            try action()
            checks[name] = ["status": "passed"]
        } catch {
            checks[name] = ["status": "failed", "error": String(describing: error)]
        }
    }
    assess("restoredFixture") { try assertFixture(restored, root: root) }
    assess("roundTrip") { try compareRoundTrip(seed: seeded, restored: restored) }
    if grouped {
        assess("organizationPersistence") { try compareOrganizationStore(seed: seeded, restored: restored) }
    }
    assess("childSessions") {
        let secondSessions = try sessionEvidence("restore", root: root)
        report["sessions"] = ["seed": firstSessions, "restore": secondSessions]
        try assertSessions(restored, files: secondSessions)
        try require(Set(firstSessions.compactMap { $0["nonce"] as? String }).isDisjoint(with: Set(secondSessions.compactMap { $0["nonce"] as? String })),
                    "Restored session handshakes are not fresh")
        for (phase, sessions) in [("seed", firstSessions), ("restore", secondSessions)] {
            let expectedPWDs = Set(directories(for: phase).map { root.appendingPathComponent($0).path })
            try require(Set(sessions.compactMap { $0["pwd"] as? String }) == expectedPWDs, "Actual child process working directories differ")
            try require(Set(sessions.compactMap { $0["pid"] as? Int }).count == expectedPWDs.count, "Child session PID count differs")
        }
    }
    assess("orderlyRestoreExit") { try orderlyQuit("restore") }
    assess("nativeEvidence") { try assertNativeEvidence(seed: seeded, restore: restored) }
    assess("preQuitRoundTrip") {
        guard let final = try records("restore").last(where: { $0["event"] as? String == "preQuitObserved" }) else {
            throw GateFailure("Missing final observation before orderly quit")
        }
        try compareRoundTrip(seed: seeded, restored: final, evidenceKey: "finalRoundTripDifferences")
        try compareOrganizationStore(seed: seeded, restored: final)
    }
    report["checks"] = checks
    let failures = checks.keys.sorted().compactMap { name -> String? in
        guard checks[name]?["status"] as? String == "failed" else { return nil }
        return name + ": " + (checks[name]?["error"] as? String ?? "unknown")
    }
    let differences = (report["roundTripDifferences"] as? [[String: Any]] ?? []) +
        (report["finalRoundTripDifferences"] as? [[String: Any]] ?? [])
    if checks["nativeEvidence"]?["status"] as? String == "passed",
       differences.contains(where: { ["tabOrder", "selectedTab"].contains($0["field"] as? String ?? "") }) {
        report["decisionRecommendation"] = "Native tab order/selection differs after coherent event propagation. Keep the native organization gate blocked and investigate the recorded AppKit sequence; do not synthesize selection or change native lifecycle to pass."
    }
    try require(failures.isEmpty, failures.joined(separator: "; "))
    report["status"] = "passed"
}

do {
    try run()
} catch {
    report["error"] = String(describing: error)
    if let app = currentApplication, !app.isTerminated, let phase = currentPhase {
        do {
            try orderlyQuit(phase, checkingFailures: false)
        } catch {
            report["cleanupError"] = String(describing: error)
        }
    }
}
if let app = currentApplication, app.isTerminated, let phase = currentPhase {
    exits[phase] = ["pid": Int(app.processIdentifier), "terminated": true, "orderlyVerified": false]
}
report["exits"] = exits
if let app = currentApplication, !app.isTerminated {
    report["leftRunningPID"] = Int(app.processIdentifier)
    report["recovery"] = "Orderly cleanup did not finish. Quit only this dedicated probe app normally; no force termination or relaunch was attempted."
}
if evidenceDirectory != nil {
    for phase in ["seed", "restore"] {
        do {
            let events = try records(phase)
            report[phase + "Ordering"] = events
            report[phase + "Failures"] = events.filter { $0["event"] as? String == "failure" }
            if let latest = events.last(where: { ["stateObserved", "preQuitObserved"].contains($0["event"] as? String ?? "") }) {
                report[phase + "FinalObservation"] = latest
            }
        } catch {
            report[phase + "EvidenceError"] = String(describing: error)
            report["status"] = "failed"
        }
    }
}
if report["status"] as? String == "failed", report["decisionRecommendation"] == nil,
   report["restore"] == nil, let latest = report["restoreFinalObservation"] as? [String: Any] {
    report["decisionRecommendation"] = "No coherent live restoration boundary was reached. Inspect restoreFinalObservation.waitingFor and restoreOrdering before attributing the failure to saved native selection; do not synthesize selection."
    report["unresolvedObservation"] = latest["waitingFor"] ?? []
}
if let root = evidenceDirectory {
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
        try FileHandle.standardOutput.write(contentsOf: data)
        print()
    } catch {
        fputs("Cannot write result.json: \(error)\n", stderr)
        exit(1)
    }
} else {
    fputs("\(report["error"] ?? "Probe setup failed")\n", stderr)
}
exit(report["status"] as? String == "passed" ? 0 : 1)
