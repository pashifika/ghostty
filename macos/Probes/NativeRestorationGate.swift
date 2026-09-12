import AppKit
import Foundation
import Darwin

// Standalone executable; intentionally outside the app and XCTest source roots.
// Build the DEBUG app with a fresh dev.pashifika.ghostty.organization-probe.<unique> bundle ID.
// Run: xcrun swift macos/Probes/NativeRestorationGate.swift /absolute/Ghostty.app /new/evidence-directory [mode] [seed|verify-explicit|verify-auto]
// Host modes only seed/verify a resumable fixture. They never initiate a host event.
// No ApplePersistenceIgnoreState, fixture decoding, forced termination, or timed restore barrier.
// The deadline only fails a stalled run. All success conditions come from native events.

private var bundleID = ""
private let fileManager = FileManager.default
private let timeout: TimeInterval = 60
private let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "native"
private let workflow = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "run"
private let supportedModes = [
    "native", "groups", "groups-partial", "groups-never", "groups-precolor", "groups-pwd-cleared",
    "groups-cwd-changed", "groups-close-cancel", "groups-quit-cancel", "groups-quick-create", "groups-quick-close",
    "groups-missing-home", "groups-missing-configured", "groups-prepared-mutated",
    "groups-shutdown", "groups-restart", "groups-logout", "groups-reason-missing", "groups-reason-unknown",
    "groups-pending-quit", "groups-pending-repeat", "groups-pending-core-quit",
    "groups-host-shutdown", "groups-host-restart", "groups-relaunch-context", "groups-background-restore"
]
private let exerciseModes = [
    "groups-host-shutdown", "groups-host-restart",
    "groups-cwd-changed", "groups-close-cancel", "groups-quit-cancel",
    "groups-shutdown", "groups-restart", "groups-logout", "groups-reason-missing", "groups-reason-unknown"
]
private var hostMode: Bool { mode.hasPrefix("groups-host-") }
private var bundledLaunchContext: Bool { hostMode || mode == "groups-relaunch-context" }
private var missingDirectory: Bool { mode == "groups-missing-home" || mode == "groups-missing-configured" }
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
    "scope": "Two real launches; app-level reasons do not prove host shutdown/restart/logout",
    "hostLifecycleVerified": false,
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

private func probeEnvironment(root: URL, phase: String) -> [String: String] {
    [
        "GHOSTTY_ORGANIZATION_PROBE": "restore",
        "GHOSTTY_ORGANIZATION_PROBE_DIRECTORY": root.path,
        "GHOSTTY_ORGANIZATION_PROBE_RUN": runID,
        "GHOSTTY_ORGANIZATION_PROBE_PHASE": phase,
        "GHOSTTY_USER_DEFAULTS_SUITE": bundleID + "." + runID,
        "GHOSTTY_CONFIG_PATH": root.appendingPathComponent("config").path,
        "GHOSTTY_ORGANIZATION_PROBE_MODE": mode,
        "LLVM_PROFILE_FILE": root.appendingPathComponent("profiles/%p-%m.profraw").path,
        "ENV": "", "BASH_ENV": ""
    ]
}

private func persistLaunchContext(app: URL, root: URL) throws {
    try require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                "Cannot change launch context of a running probe app")
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard var info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == bundleID else {
        throw GateFailure("Probe bundle identity changed before context installation")
    }
    var environment = info["LSEnvironment"] as? [String: String] ?? [:]
    environment.merge(probeEnvironment(root: root, phase: "restore")) { _, new in new }
    info["LSEnvironment"] = environment
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: infoURL, options: .atomic)
    for arguments in [["--force", "--deep", "--sign", "-", app.path],
                      ["--verify", "--deep", "--strict", app.path]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0,
                    "Cannot sign isolated launch context: " + (String(data: diagnostics, encoding: .utf8) ?? "unknown"))
    }
    report["bundledLaunchContext"] = probeEnvironment(root: root, phase: "restore")
}

private func validateProbeProcess(_ application: NSRunningApplication, start: [String: Any], root: URL) throws {
    try require(application.bundleIdentifier == bundleID, "LaunchServices opened the wrong bundle")
    try require(start["pid"] as? Int == Int(application.processIdentifier), "Probe PID differs from launched application")
    try require(start["ignoreState"] as? Bool == false && start["keepWindows"] as? Bool == true, "Native Resume is disabled")
    try require(start["suite"] as? String == bundleID + "." + runID, "Wrong defaults suite")
    try require(start["config"] as? String == root.appendingPathComponent("config").path, "Wrong config on launch")
}

private func observeAutomaticLaunch(app: URL, root: URL) throws {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    try require(applications.count == 1, "Automatic verification requires exactly one running probe app")
    let application = applications[0]
    try require(application.bundleURL?.standardizedFileURL == app.standardizedFileURL,
                "Running probe came from a different app bundle")
    guard let start = try records("restore").first(where: { $0["event"] as? String == "probeStarted" }) else {
        throw GateFailure("Automatically reopened app has no controlled restore context; it was not touched")
    }
    try validateProbeProcess(application, start: start, root: root)
    currentApplication = application
    currentPhase = "restore"
    report["restoreLaunchMode"] = "automatic-observed"
    report["activatedForInspection"] = !application.isActive
    if !application.isActive { _ = application.activate(options: []) }
}

private func launch(_ appURL: URL, root: URL, phase: String) throws {
    currentPhase = phase
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GHOSTTY_") }
    environment.merge(probeEnvironment(root: root, phase: phase)) { _, new in new }
    let configuration = NSWorkspace.OpenConfiguration()
    let environmentFree = phase == "restore" && bundledLaunchContext
    configuration.environment = environmentFree ? [:] : environment
    report[phase + "LaunchEnvironment"] = environmentFree ? "bundle LSEnvironment only" : "explicit seed environment"
    configuration.arguments = []
    configuration.activates = !(phase == "restore" && mode == "groups-background-restore")
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
    guard let application = currentApplication else { throw GateFailure("LaunchServices returned no probe app") }
    try validateProbeProcess(application, start: event("probeStarted", phase: phase), root: root)
}

private func orderlyQuit(_ phase: String, checkingFailures: Bool = true) throws {
    guard let application = currentApplication else { throw GateFailure("No launched probe application to quit") }
    try require(application.bundleIdentifier == bundleID && currentPhase == phase, "Refusing to quit an unrelated application")
    if !checkingFailures, !application.isActive {
        _ = application.activate(options: [])
        try waitUntil("Cleanup activation") { application.isActive }
    }
    send(checkingFailures ? "quit" : "cleanup")
    _ = try event("orderlyQuitRequested", phase: phase, checkingFailures: false)
    let termination = try event("applicationWillTerminate", phase: phase, checkingFailures: checkingFailures)
    try require(termination["orderlyQuitRequested"] as? Bool == true, "Termination did not use the requested app quit path")
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
    var values = grouped ? ["a", "b", "c", "d", "e"] : ["a", "b", "c"]
    if phase == "restore" {
        if mode == "groups-partial" { values.removeAll { $0 == "c" } }
        if mode == "groups-quick-close" { values.removeAll { $0 == "e" } }
        if mode == "groups-quick-create" { values.append("f") }
    }
    return values
}

private func expectedDirectory(_ original: String, root: URL, restoring: Bool) -> String {
    guard restoring else { return original }
    if missingDirectory, original == root.appendingPathComponent("c").path {
        return mode == "groups-missing-home"
            ? fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            : root.appendingPathComponent("configured").path
    }
    return original
}

private func expectedFixturePWDs(phase: String, root: URL) -> Set<String> {
    Set(directories(for: phase).map { directory in
        var value = root.appendingPathComponent(directory).path
        if phase == "restore" {
            switch (mode, directory) {
            case ("groups-cwd-changed", "a"): value = root.appendingPathComponent("a-next").path
            case ("groups-cwd-changed", "c"),
                 ("groups-quit-cancel", "c"), ("groups-reason-missing", "c"), ("groups-reason-unknown", "c"):
                value = root.appendingPathComponent("c-next").path
            case ("groups-cwd-changed", "d"):
                value = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            case ("groups-close-cancel", "e"): value = root.appendingPathComponent("e-next").path
            default: break
            }
        }
        return expectedDirectory(value, root: root, restoring: phase == "restore")
    })
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
    let expectedPWDs = expectedFixturePWDs(phase: phase, root: root)
    try require(Set(leaves.compactMap { $0["pwd"] as? String }) == expectedPWDs, "Actual terminal PWDs differ from the fixture")
    try require(leaves.allSatisfy {
        $0["restorationDirectory"] as? String == $0["pwd"] as? String
    }, "The observed usable child directory was not retained")
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
            if key == "surfaces", let leaves = old as? [[String: Any]], let root = evidenceDirectory {
                old = leaves.map { leaf -> [String: Any] in
                    var expected = leaf
                    let saved = leaf["restorationDirectory"] as? String ?? ""
                    let directory = expectedDirectory(saved, root: root, restoring: true)
                    // Presentation may deliberately clear; the expected live PWD
                    // after relaunch comes from the separately checked saved input.
                    expected["pwd"] = directory
                    expected["restorationDirectory"] = directory
                    return expected
                }
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
            let saved = report["savedDirectories"] as? [String: String] ?? [:]
            let id = session["surface"] as? String ?? ""
            try require(decoded[id] == saved[id] && !(saved[id] ?? "").isEmpty,
                        "Native decoder did not read the expected saved per-surface directory")
            guard let root = evidenceDirectory, let candidate = saved[id] else {
                throw GateFailure("Missing saved-directory expectation")
            }
            try require(session["pwd"] as? String == expectedDirectory(candidate, root: root, restoring: true),
                        "Actual restored child /bin/pwd -P did not follow the saved directory or configured fallback")
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
    let backgroundRestore = mode == "groups-background-restore"
    let completion = backgroundRestore ? try event("backgroundRestoreReady", phase: "restore") : restore
    let observedSequence = completion["sequence"] as? Int ?? -1
    let allowedWaiting = backgroundRestore ? ["firstActivation", "organization reconciliation completion"] : []
    try require(completion["boundary"] as? String == report["observationBoundary"] as? String &&
                (completion["waitingFor"] as? [String])?.allSatisfy({ allowedWaiting.contains($0) }) == true &&
                barrierSequence < observedSequence, "Observation was not after native completion and event propagation")
    if backgroundRestore {
        try require(restore["event"] as? String == "preparedSnapshot" &&
                    restore["organizationRestoring"] as? Bool == false &&
                    (restore["sequence"] as? Int ?? -1) > observedSequence,
                    "Background native completion did not precede coherent termination capture")
    }
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
    guard let agreements = completion["focusRequests"] as? [[String: Any]] else { throw GateFailure("Missing final per-request focus readback") }
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
    let expectedSeedCreations = directories(for: "seed").count + (mode == "groups-quick-create" ? 1 : 0)
    try require(first.filter { $0["event"] as? String == "surfaceCreated" }.count == expectedSeedCreations &&
                !first.contains { $0["event"] as? String == "surfaceDecoded" || $0["event"] as? String == "nativeRestoreBegan" }, "First launch was not a clean seed")
    let encoded = first.filter { $0["event"] as? String == "windowEncoded" }
    report["nativeEncodingsAfterPreparation"] = encoded.filter {
        ($0["sequence"] as? Int ?? -1) > (seed["sequence"] as? Int ?? .max)
    }.count
    for tab in try windows(seed) where tab["restorable"] as? Bool == true {
        guard let matching = encoded.last(where: { $0["identity"] as? String == tab["identity"] as? String }) else {
            throw GateFailure("Native encoder did not capture a seeded window")
        }
        for key in ["tree", "focusedSurface", "tabOrder", "selectedTab"] {
            guard let encodedValue = matching[key], let savedValue = tab[key] else {
                throw GateFailure("Missing native encoder field " + key)
            }
            try require(try canonical([encodedValue]) == canonical([savedValue]), "Native encoder captured stale " + key)
        }
        let savedLeaves = try surfaces([tab])
        let encodedLeaves = try surfaces([matching])
        try require(Set(encodedLeaves.compactMap { $0["id"] as? String }) == Set(savedLeaves.compactMap { $0["id"] as? String }),
                    "Live native encoder readback omitted or duplicated a captured surface")
        if mode != "groups-prepared-mutated" {
            for leaf in savedLeaves {
                let live = encodedLeaves.first { $0["id"] as? String == leaf["id"] as? String }
                try require(live?["restorationDirectory"] as? String == leaf["restorationDirectory"] as? String,
                            "Retained directory was already stale at the native encoder callback")
            }
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

private func assertSeedTransition(initial: [String: Any], prepared: [String: Any], root: URL) throws {
    let initialTabs = try windows(initial)
    let initialLeaves = try surfaces(initialTabs)
    var expected: [String: String] = [:]
    for leaf in initialLeaves {
        guard let id = leaf["id"] as? String, let pwd = leaf["pwd"] as? String else {
            throw GateFailure("Missing initial directory association")
        }
        expected[id] = pwd
    }
    func initialID(_ name: String) throws -> String {
        guard let id = initialLeaves.first(where: { $0["pwd"] as? String == root.appendingPathComponent(name).path })?["id"] as? String else {
            throw GateFailure("Missing initial surface for " + name)
        }
        return id
    }
    if mode == "groups-cwd-changed" {
        expected[try initialID("a")] = root.appendingPathComponent("a-next").path
        expected[try initialID("c")] = root.appendingPathComponent("c-next").path
        expected[try initialID("d")] = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }
    if ["groups-quit-cancel", "groups-reason-missing", "groups-reason-unknown"].contains(mode) {
        expected[try initialID("c")] = root.appendingPathComponent("c-next").path
    }
    if mode == "groups-close-cancel" { expected[try initialID("e")] = root.appendingPathComponent("e-next").path }
    if mode == "groups-quick-close" { expected.removeValue(forKey: try initialID("e")) }
    if mode == "groups-quick-create" {
        let created = try event("quickCreated", phase: "seed")
        guard let id = created["surface"] as? String else { throw GateFailure("Missing rapidly created surface") }
        try require(expected[id] == nil, "Rapid creation reused an existing surface identity")
        expected[id] = root.appendingPathComponent("f").path
    }
    report["savedDirectories"] = expected
    let preparedTabs = try windows(prepared)
    let preparedLeaves = try surfaces(preparedTabs)
    let ids = preparedLeaves.compactMap { $0["id"] as? String }
    try require(ids.count == expected.count && Set(ids) == Set(expected.keys),
                "Successful preparation omitted a completed creation, kept a completed close, or removed a canceled close")
    for leaf in preparedLeaves {
        let id = leaf["id"] as? String ?? ""
        try require(leaf["restorationDirectory"] as? String == expected[id],
                    "Pre-termination retained directory differs from the real fixture transition")
    }
    // Check the changed membership against the initial organization, not only
    // against a later snapshot that could already have lost the completed edit.
    if grouped, let original = initialTabs.first?["organization"] as? [String: Any] {
        let finalIDs = Set(preparedTabs.compactMap { $0["organizationTabID"] as? String })
        var expectedUnassigned = (original["unassigned"] as? [String] ?? []).filter { finalIDs.contains($0) }
        if mode == "groups-quick-create" {
            let oldIDs = Set(initialTabs.compactMap { $0["organizationTabID"] as? String })
            let added = finalIDs.subtracting(oldIDs)
            try require(added.count == 1, "Rapid tab creation did not retain one new organization identity")
            expectedUnassigned += added.sorted()
        }
        for tab in preparedTabs {
            guard let organization = tab["organization"] as? [String: Any] else {
                throw GateFailure("Missing prepared organization")
            }
            try require(try canonical(organization["groups"] ?? []) == canonical(original["groups"] ?? []),
                        "Directory/close/create exercise changed unrelated groups, members, order or colors")
            try require(organization["unassigned"] as? [String] == expectedUnassigned,
                        "Prepared organization missed the completed unassigned-tab edit")
            if let originalTab = initialTabs.first(where: { $0["organizationTabID"] as? String == tab["organizationTabID"] as? String }) {
                try require(originalTab["tabColor"] as? Int == tab["tabColor"] as? Int,
                            "Fixture exercise changed an independent tab color")
            }
        }
    }
}

private func assertTerminationEvidence(phase: String) throws {
    let events = try records(phase)
    let decisions = events.filter { $0["event"] as? String == "terminationDecision" }
    let requested = decisions.filter { $0["stage"] as? String == "requested" }
    let replies = decisions.filter { $0["stage"] as? String == "reply" }
    let confirmations = events.filter { $0["event"] as? String == "confirmationObserved" && $0["kind"] as? String == "app" }
    let cancellation = phase == "seed" && ["groups-quit-cancel", "groups-reason-missing", "groups-reason-unknown"].contains(mode)
    let systemExit = (phase == "seed" && ["groups-shutdown", "groups-restart", "groups-logout", "groups-host-shutdown", "groups-host-restart"].contains(mode)) ||
        (phase == "restore" && mode == "groups-background-restore")
    try require(replies.filter { $0["reply"] as? String == "terminateNow" }.count == 1,
                "The actual delegate did not produce exactly one final accepted reply")
    try require(replies.filter { $0["reply"] as? String == "terminateCancel" }.count == (cancellation ? 1 : 0),
                "Actual quit cancellation differs from the requested scenario")
    try require(decisions.filter { $0["stage"] as? String == "preparationCompleted" }.count == 1 &&
                !decisions.contains { $0["stage"] as? String == "preparationFailed" },
                "Termination did not complete exactly one successful capture")
    try require(!requested.isEmpty, "Missing actual AppDelegate termination entry")
    if systemExit || (phase == "seed" && mode.hasPrefix("groups-reason-")) {
        let first = requested[0]
        try require(first["eventPresent"] as? Bool == true &&
                    first["eventClass"] as? Int == Int(kCoreEventClass) &&
                    first["eventID"] as? Int == Int(kAEQuitApplication),
                    "The submitted quit did not reach the delegate as an actual quit AppleEvent")
        let expectedReason: Int?
        switch mode {
        case "groups-shutdown", "groups-host-shutdown", "groups-background-restore": expectedReason = Int(kAEShutDown)
        case "groups-restart", "groups-host-restart": expectedReason = Int(kAERestart)
        case "groups-logout": expectedReason = Int(kAEReallyLogOut)
        case "groups-reason-unknown": expectedReason = 0x70726F62
        default: expectedReason = nil
        }
        try require(first["reasonPresent"] as? Bool == (expectedReason != nil) &&
                    first["reason"] as? Int == (expectedReason ?? -1),
                    "Actual native delivery lost or changed the termination reason")
        try require(first["needsConfirmQuit"] as? Bool == true,
                    "System/unknown-reason scenario had no real confirmation requirement")
    }
    if systemExit {
        if hostMode {
            let operatorObservation = report["hostOperatorObservation"] as? [String: Any]
            try require(operatorObservation?["ghosttyConfirmation"] as? String == "absent",
                        "The operator reported a Ghostty confirmation during the authorized host exit")
        }
        try require(confirmations.isEmpty &&
                    !decisions.contains { $0["stage"] as? String == "confirmationPresented" },
                    "Recognized system exit displayed a Ghostty confirmation")
    } else if !(phase == "restore" && mode == "groups-never") {
        try require(confirmations.filter { $0["action"] as? String == "accept" }.count == 1 &&
                    confirmations.filter { $0["action"] as? String == "cancel" }.count == (cancellation ? 1 : 0),
                    "Ordinary quit did not exercise its actual visible confirmation buttons")
        try require(decisions.filter { $0["stage"] as? String == "confirmationAccepted" }.count == 1 &&
                    decisions.filter { $0["stage"] as? String == "confirmationCancelled" }.count == (cancellation ? 1 : 0),
                    "AppDelegate did not observe the expected real modal result")
    }
    if cancellation {
        guard let canceled = replies.first(where: { $0["reply"] as? String == "terminateCancel" }),
              let update = events.last(where: { $0["event"] as? String == "childDirectoryObserved" }),
              let prepared = events.last(where: { $0["event"] as? String == "preparedSnapshot" }) else {
            throw GateFailure("Missing canceled-quit continuation evidence")
        }
        try require((canceled["sequence"] as? Int ?? .max) < (update["sequence"] as? Int ?? -1) &&
                    (update["sequence"] as? Int ?? .max) < (prepared["sequence"] as? Int ?? -1),
                    "Saving did not resume after cancellation and capture the later actual directory change")
    }
    if phase == "seed", mode.hasPrefix("groups-pending-") {
        let deferred = replies.filter { $0["reply"] as? String == "terminateLater" }
        let repeated = mode == "groups-pending-repeat"
        try require(deferred.count == (repeated ? 2 : 1) && requested.count == (repeated ? 2 : 1),
                    "Real native pending work did not produce the expected deferred/repeated replies")
        guard let merge = events.first(where: { $0["event"] as? String == "nativeMergeRequested" }),
              let firstDeferred = deferred.first,
              let completion = decisions.first(where: { $0["stage"] as? String == "preparationCompleted" }) else {
            throw GateFailure("Missing native merge/deferred completion evidence")
        }
        try require((merge["sequence"] as? Int ?? .max) < (firstDeferred["sequence"] as? Int ?? -1) &&
                    (firstDeferred["sequence"] as? Int ?? .max) < (completion["sequence"] as? Int ?? -1),
                    "Pending native merge was not completed before successful final capture")
        if mode == "groups-pending-core-quit" {
            guard let returned = events.first(where: { $0["event"] as? String == "coreQuitBindingReturned" }),
                  let entry = requested.first else {
                throw GateFailure("Missing real queued core quit evidence")
            }
            try require(returned["performed"] as? Bool == true &&
                        (returned["sequence"] as? Int ?? .max) < (entry["sequence"] as? Int ?? -1),
                        "The core binding did not return from its queued caller before Cocoa termination entry")
        }
        if repeated {
            try require(events.filter {
                $0["event"] as? String == "repeatedQuitReturned" && $0["terminateLater"] as? Bool == true
            }.count == 1, "Actual repeated delegate entry did not share the pending attempt")
        }
    }
    if phase == "seed", systemExit || cancellation {
        let runningJobs = requested.first?["runningJobPIDs"] as? [Int] ?? []
        try require(!runningJobs.isEmpty && events.contains {
            $0["event"] as? String == "childDirectoryObserved" && $0["jobRunning"] as? Bool == true &&
                runningJobs.contains($0["jobPID"] as? Int ?? -1)
        }, "The confirmation scenario had no observed child job still running at the actual quit request")
    }
}

private func assertExerciseEvidence(root: URL) throws {
    let events = try records("seed")
    let requests = events.filter { $0["event"] as? String == "directoryChangeRequested" }
    if mode == "groups-cwd-changed" {
        try require(requests.contains {
            $0["directory"] as? String == root.appendingPathComponent("a-next").path &&
                $0["focused"] as? Bool == false && $0["controllerFocused"] as? Bool == false
        }, "The changed split was not actually unfocused")
        try require(requests.contains {
            $0["directory"] as? String == root.appendingPathComponent("c-next").path && $0["selected"] as? Bool == false
        }, "The changed tab was not actually in the background")
    }
    if mode == "groups-close-cancel" || mode == "groups-quick-close" {
        let completed = mode == "groups-quick-close"
        let outcomes = events.filter { $0["event"] as? String == "closeOutcome" }
        try require(outcomes.count == 1 && outcomes[0]["closed"] as? Bool == completed &&
                    outcomes[0]["stillLive"] as? Bool == !completed,
                    "Actual native close completion disagrees with its cancellation/acceptance")
        try require(events.filter {
            $0["event"] as? String == "confirmationObserved" && $0["kind"] as? String == "tab" &&
                $0["action"] as? String == (completed ? "accept" : "cancel")
        }.count == 1, "Tab close did not exercise its actual owned confirmation")
    }
    if mode == "groups-pwd-cleared" {
        let cleared = events.filter { $0["event"] as? String == "directoryCleared" }
        let beforeQuit = try event("preQuitObserved", phase: "seed")
        let leaves = try surfaces(windows(beforeQuit))
        try require(cleared.count == leaves.count && leaves.allSatisfy {
            $0["pwd"] as? String == "" && !($0["restorationDirectory"] as? String ?? "").isEmpty
        }, "Unknown-PWD scenario did not clear the display while retaining real restoration input")
    }
    if mode == "groups-quick-create" {
        let created = try event("quickCreated", phase: "seed")
        let id = created["surface"] as? String
        try require(created["pwd"] as? String == "" &&
                    created["restorationDirectory"] as? String == root.appendingPathComponent("f").path &&
                    !events.contains {
                        $0["event"] as? String == "surfacePWD" && $0["surface"] as? String == id &&
                            !($0["pwd"] as? String ?? "").isEmpty
                    } && !events.contains {
                        $0["event"] as? String == "childSessionObserved" && $0["surface"] as? String == id
                    }, "Rapid creation did not exercise termination before its first shell report")
    }
    if mode == "groups-prepared-mutated" {
        let mutations = events.filter { $0["event"] as? String == "preparedDirectoryMutated" }
        try require(mutations.count == directories(for: "seed").count, "Immutable-input fixture did not mutate every captured directory")
        let postMutation = try event("postPreparationState", phase: "seed")
        let changedLeaves = try surfaces(windows(postMutation))
        for mutation in mutations {
            let id = mutation["surface"] as? String
            let changed = changedLeaves.first { $0["id"] as? String == id }
            try require(mutation["captured"] as? String != mutation["replacement"] as? String &&
                        changed?["restorationDirectory"] as? String == mutation["replacement"] as? String,
                        "The live retained directory did not change after capture")
        }
        report["nativeEncodingsAfterMutation"] = events.filter {
            $0["event"] as? String == "windowEncoded" &&
                ($0["sequence"] as? Int ?? -1) > (postMutation["sequence"] as? Int ?? .max)
        }.count
    }
    if missingDirectory {
        try require(!fileManager.fileExists(atPath: root.appendingPathComponent("c").path) &&
                    fileManager.fileExists(atPath: root.appendingPathComponent("c.disappeared").path),
                    "Restoration recreated the disappeared saved directory")
    }
}

private func bootSessionUUID() throws -> String {
    var size = 0
    try require(sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 && size > 1,
                "Cannot identify the current boot session")
    var bytes = [CChar](repeating: 0, count: size)
    let result = bytes.withUnsafeMutableBytes { buffer in
        sysctlbyname("kern.bootsessionuuid", buffer.baseAddress, &size, nil, 0)
    }
    try require(result == 0, "Cannot read the current boot session")
    let value = String(cString: bytes)
    try require(UUID(uuidString: value) != nil, "Invalid boot session UUID")
    return value
}

private func readObject(_ url: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw GateFailure("Invalid evidence object: " + url.path)
    }
    return value
}

private func prepareHostVerification(app: URL, root: URL) throws {
    let manifest = try readObject(root.appendingPathComponent("host-fixture.json"))
    guard let savedRun = manifest["run"] as? String, UUID(uuidString: savedRun) != nil else {
        throw GateFailure("Missing resumable fixture run identity")
    }
    try require(manifest["app"] as? String == app.path && manifest["bundleID"] as? String == bundleID &&
                manifest["mode"] as? String == mode && manifest["directory"] as? String == root.path,
                "Resumed fixture does not match the exact seed app, mode and evidence directory")
    try require(UserDefaults(suiteName: bundleID)?.string(forKey: "GhosttyProbeRun") == savedRun,
                "Resumed fixture does not own this dedicated bundle")
    let currentBoot = try bootSessionUUID()
    try require(manifest["bootSessionUUID"] as? String != currentBoot,
                "Host verification requires a different boot; app quit/relaunch is not host proof")
    try require(!fileManager.fileExists(atPath: root.appendingPathComponent("result.json").path),
                "A host result already exists; refusing to overwrite it")
    let restoreExists = fileManager.fileExists(atPath: root.appendingPathComponent("restore.jsonl").path)
    try require(workflow == "verify-auto" ? restoreExists : !restoreExists,
                "Use verify-auto for an already reopened controlled app; explicit verification must not relaunch it")
    let observation = try readObject(root.appendingPathComponent("host-observation.json"))
    let action = mode == "groups-host-shutdown" ? "shutdown" : "restart"
    try require(observation["authorized"] as? Bool == true && observation["action"] as? String == action &&
                observation["launchMode"] as? String == (workflow == "verify-auto" ? "automatic" : "explicit") &&
                ["absent", "present"].contains(observation["ghosttyConfirmation"] as? String ?? "") &&
                observation["otherDialogs"] is String && observation["notes"] is String,
                "Operator must record authorized action, matching launch mode, Ghostty confirmation, other dialog owners and notes")
    runID = savedRun
    evidenceDirectory = root
    report["hostSeed"] = manifest
    report["hostOperatorObservation"] = observation
    report["bootSessionUUID"] = currentBoot
    report["hostEvidenceScope"] = "Operator attestation plus different boot, actual delegate reason and native two-launch restoration. External OS dialogs remain operator-observed."
    report["config"] = try String(contentsOf: root.appendingPathComponent("config"), encoding: .utf8)
}

private func writeFixture(root: URL) throws -> String {
    for directory in directories(for: "seed") + [
        "a-next", "c-next", "e-next", "f", "configured",
        "sessions/seed", "sessions/restore", "jobs/seed", "jobs/restore", "profiles"
    ] {
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
    actual_pwd=$(/bin/pwd -P)
    if [ "$GHOSTTY_ORGANIZATION_PROBE_MODE" = groups-quick-create ] &&
       [ "$GHOSTTY_ORGANIZATION_PROBE_PHASE" = seed ] &&
       [ "$actual_pwd" = "$GHOSTTY_ORGANIZATION_PROBE_DIRECTORY/f" ]; then
        exec /bin/sleep 300
    fi
    nonce=$(/usr/bin/uuidgen)
    GHOSTTY_PROBE_SESSION_NONCE="$nonce"
    export GHOSTTY_PROBE_SESSION_NONCE
    /usr/bin/printf '%s\\n%s\\n%s\\n%s\\n%s\\n' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$$" "$nonce" "$actual_pwd" > "$directory/.$nonce"
    /bin/mv "$directory/.$nonce" "$directory/$nonce"
    /usr/bin/printf '\\033]7;file://localhost%s\\007' "$actual_pwd"
    /usr/bin/printf '\\033]2;ghostty-native-session:%s:%s:%s\\007' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$nonce"
    exec /bin/sh -i
    """
    try shellSource.write(to: shell, atomically: true, encoding: .utf8)
    let update = """
    # Sourced only by the controlled probe shell; never reads user startup files.
    token="$1"
    nonce="$GHOSTTY_PROBE_SESSION_NONCE"
    directory="$GHOSTTY_ORGANIZATION_PROBE_DIRECTORY/sessions/$GHOSTTY_ORGANIZATION_PROBE_PHASE"
    if [ "$2" = job ]; then
        /bin/sleep 86400 &
        job_pid=$!
        kill -0 "$job_pid" || return 1
        /usr/bin/printf '%s\\n' "$job_pid" > "$GHOSTTY_ORGANIZATION_PROBE_DIRECTORY/jobs/$GHOSTTY_ORGANIZATION_PROBE_PHASE/$nonce" || return 1
    fi
    actual_pwd=$(/bin/pwd -P) || return 1
    /usr/bin/printf '%s\\n%s\\n%s\\n%s\\n%s\\n' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$$" "$nonce" "$actual_pwd" > "$directory/.$nonce" || return 1
    /bin/mv "$directory/.$nonce" "$directory/$nonce" || return 1
    /usr/bin/printf '\\033]7;file://localhost%s\\007' "$actual_pwd"
    /usr/bin/printf '\\033]2;ghostty-native-update:%s:%s:%s\\007' "$GHOSTTY_ORGANIZATION_PROBE_RUN" "$GHOSTTY_ORGANIZATION_PROBE_PHASE" "$token"
    """
    try update.write(to: root.appendingPathComponent("report-update.sh"), atomically: true, encoding: .utf8)
    let quotedShell = "'" + shell.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let configuredDirectory = mode == "groups-missing-configured" ? root.appendingPathComponent("configured").path : "home"
    let config = """
    window-save-state = always
    initial-window = false
    confirm-close-surface = always
    working-directory = \(configuredDirectory)
    window-inherit-working-directory = false
    tab-inherit-working-directory = false
    split-inherit-working-directory = false
    window-new-tab-position = end
    quit-after-last-window-closed = false
    macos-titlebar-style = \(grouped ? "groups" : "native")
    shell-integration = none
    command = /bin/sh \(quotedShell)
    auto-update = off
    """
    try config.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    return config
}

private func parkHostFixture(app: URL, root: URL, seed: [String: Any]) throws {
    let manifest: [String: Any] = [
        "run": runID, "app": app.path, "bundleID": bundleID, "directory": root.path, "mode": mode,
        "bootSessionUUID": try bootSessionUUID(), "seedPID": Int(currentApplication!.processIdentifier),
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "seed": seed
    ]
    try canonical(manifest).write(to: root.appendingPathComponent("host-fixture.json"), options: .atomic)
    report["hostSeed"] = manifest
    report["status"] = "awaiting-operator"
    report["operatorSteps"] = [
        "Fixture stays running. Obtain separate operator authorization before any real host shutdown or restart; this gate does not initiate either.",
        "Leave the dedicated fixture unchanged. Observe Ghostty-owned versus OS/other-app confirmations; the host probe records but never answers its quit dialog.",
        "After the authorized host event, do not open or modify this bundle. If macOS reopened it, use verify-auto; otherwise use verify-explicit.",
        "Create host-observation.json with authorized=true, action matching mode, launchMode=automatic or explicit, ghosttyConfirmation=absent or present, and factual otherDialogs/notes strings.",
        "Resume with the same app, evidence directory and mode. Verification requires a changed boot UUID and refuses to overwrite a prior result."
    ]
    report["resumeArguments"] = [
        "automatic": [app.path, root.path, mode, "verify-auto"],
        "explicit": [app.path, root.path, mode, "verify-explicit"]
    ]
}

private func run() throws {
    try require((3...5).contains(CommandLine.arguments.count) && supportedModes.contains(mode),
                "Usage: xcrun swift macos/Probes/NativeRestorationGate.swift /absolute/Ghostty.app /new/evidence-directory [mode] [seed|verify-explicit|verify-auto]. Modes: " + supportedModes.joined(separator: ", "))
    try require(hostMode ? ["seed", "verify-explicit", "verify-auto"].contains(workflow) : workflow == "run",
                "Host modes require seed, verify-explicit or verify-auto; automated modes use no workflow argument")
    let resuming = hostMode && workflow != "seed"
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
    bundleID = Bundle(url: app)?.bundleIdentifier ?? ""
    let prefix = "dev.pashifika.ghostty.organization-probe."
    try require(bundleID.hasPrefix(prefix) && bundleID.count > prefix.count, "Use a fresh, uniquely suffixed probe bundle for each run")
    if workflow != "verify-auto" {
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                    "A probe app is already running; use verify-auto instead of launching again")
    }
    if resuming {
        try prepareHostVerification(app: app, root: root)
    } else {
        try require(!fileManager.fileExists(atPath: root.path), "Use a new evidence directory; existing evidence is never overwritten")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        evidenceDirectory = root
    }
    report["run"] = runID
    report["app"] = app.path
    report["bundleID"] = bundleID
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    report["evidenceDirectory"] = root.path
    report["mode"] = mode
    report["workflow"] = workflow
    #if arch(arm64)
    report["architecture"] = "arm64"
    #elseif arch(x86_64)
    report["architecture"] = "x86_64"
    #else
    report["architecture"] = "other"
    #endif
    report["developerDirectory"] = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "toolchain selected by xcrun"
    let config: String
    if resuming {
        config = try String(contentsOf: root.appendingPathComponent("config"), encoding: .utf8)
    } else {
        config = try writeFixture(root: root)
        if bundledLaunchContext { try persistLaunchContext(app: app, root: root) }
    }
    report["config"] = config
    report["defaultsSuite"] = bundleID + "." + runID
    if !resuming {
        try launch(app, root: root, phase: "seed")
        _ = try event("startupObserved", phase: "seed")
        send("seed")
        let initial = try event("seedReady", phase: "seed")
        report["initialSeed"] = initial
        try assertFixture(initial, root: root)
        try assertOrganizationFixture(initial, root: root)
        try assertSessions(initial, files: sessionEvidence("seed", root: root))
        var seed = initial
        if exerciseModes.contains(mode) {
            send("exercise")
            seed = try event("exerciseReady", phase: "seed")
            report["exercise"] = seed
            try assertSessions(seed, files: sessionEvidence("seed", root: root))
        }
        if hostMode {
            try parkHostFixture(app: app, root: root, seed: seed)
            return
        }
        try orderlyQuit("seed")
    } else {
        let termination = try event("applicationWillTerminate", phase: "seed")
        exits["seed"] = [
            "pid": termination["pid"] ?? -1, "terminated": true,
            "orderly": true, "evidence": "applicationWillTerminate before a different boot"
        ]
    }
    let initial = try event("seedReady", phase: "seed")
    report["initialSeed"] = initial
    guard let seeded = try records("seed").last(where: { $0["event"] as? String == "preparedSnapshot" }) else {
        throw GateFailure("The real termination path did not produce a successful prepared snapshot")
    }
    report["seed"] = seeded
    let firstSessions = try sessionEvidence("seed", root: root)
    report["sessions"] = ["seed": firstSessions]
    var seedTransitionError: Error?
    do { try assertSeedTransition(initial: initial, prepared: seeded, root: root) } catch { seedTransitionError = error }
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
    if missingDirectory {
        let missing = root.appendingPathComponent("c")
        try require(try fileManager.contentsOfDirectory(atPath: missing.path).isEmpty,
                    "Only the isolated empty fixture directory may disappear")
        let moved = root.appendingPathComponent("c.disappeared")
        try fileManager.moveItem(at: missing, to: moved)
        report["unavailableDirectory"] = [
            "savedCandidate": missing.path, "movedTo": moved.path,
            "expectedFallback": expectedDirectory(missing.path, root: root, restoring: true),
            "operation": "renamed the isolated empty fixture after orderly seed exit"
        ]
    }
    if workflow == "verify-auto" {
        try observeAutomaticLaunch(app: app, root: root)
    } else {
        try launch(app, root: root, phase: "restore")
        if mode == "groups-relaunch-context" {
            currentApplication = nil
            currentPhase = nil
            try observeAutomaticLaunch(app: app, root: root)
            report["automaticAttachmentExercise"] = true
        }
    }
    _ = try event("nativeRestorationFinished", phase: "restore")
    let backgroundRestore = mode == "groups-background-restore"
    let restored: [String: Any]
    if backgroundRestore {
        report["backgroundRestore"] = try event("backgroundRestoreReady", phase: "restore")
        try require(currentApplication?.isActive == false, "Background restore unexpectedly activated")
        try orderlyQuit("restore")
        try require(!records("restore").contains { $0["event"] as? String == "firstActivation" },
                    "Restored app required activation before it could quit")
        restored = try event("preparedSnapshot", phase: "restore")
    } else {
        restored = try event("restoreObserved", phase: "restore")
    }
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
    assess("seedTransition") { if let error = seedTransitionError { throw error } }
    assess("exerciseEvidence") { try assertExerciseEvidence(root: root) }
    assess("seedTermination") { try assertTerminationEvidence(phase: "seed") }
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
        let expectedPWDs = expectedFixturePWDs(phase: "restore", root: root)
        try require(Set(secondSessions.compactMap { $0["pwd"] as? String }) == expectedPWDs,
                    "Actual restored child process working directories differ")
        try require(Set(secondSessions.compactMap { $0["pid"] as? Int }).count == directories(for: "restore").count,
                    "Restored child session PID count differs")
    }
    if workflow == "verify-auto", checks.values.contains(where: { $0["status"] as? String == "failed" }) {
        report["checks"] = checks
        throw GateFailure("Automatic restore checks failed; the running app was preserved for inspection")
    }
    assess("orderlyRestoreExit") { if !backgroundRestore { try orderlyQuit("restore") } }
    assess("restoreTermination") { try assertTerminationEvidence(phase: "restore") }
    assess("nativeEvidence") { try assertNativeEvidence(seed: seeded, restore: restored) }
    assess("preQuitRoundTrip") {
        let finalEvent = backgroundRestore ? "preparedSnapshot" : "preQuitObserved"
        guard let final = try records("restore").last(where: { $0["event"] as? String == finalEvent }) else {
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
    if hostMode {
        report["hostFixtureVerified"] = true
        report["hostAcceptance"] = "Native fixture and recorded operator evidence passed; the parent must reconcile host authorization, launch mode and OS-owned dialogs before accepting the Change."
    }
    report["status"] = "passed"
}

do {
    try run()
} catch {
    report["error"] = String(describing: error)
    if workflow != "verify-auto", let app = currentApplication, !app.isTerminated, let phase = currentPhase {
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
    report["recovery"] = report["status"] as? String == "awaiting-operator"
        ? "Expected live host fixture; follow operatorSteps. No host action was initiated."
        : "Orderly cleanup did not finish. Quit only this dedicated probe app normally; no force termination or relaunch was attempted."
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
        let filename = hostMode && workflow == "seed" ? "seed-result.json" : "result.json"
        try data.write(to: root.appendingPathComponent(filename), options: .atomic)
        try FileHandle.standardOutput.write(contentsOf: data)
        print()
    } catch {
        fputs("Cannot write result.json: \(error)\n", stderr)
        exit(1)
    }
} else {
    fputs("\(report["error"] ?? "Probe setup failed")\n", stderr)
}
exit(["passed", "awaiting-operator"].contains(report["status"] as? String ?? "") ? 0 : 1)
