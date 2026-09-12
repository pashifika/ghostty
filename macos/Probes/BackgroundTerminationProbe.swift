import Cocoa

// Run with a fresh dedicated DEBUG app, a new evidence directory, and always|never.
// Exercises ordinary background quit only; never initiates host shutdown.
private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure(message) }
}

private func waitFor(_ seconds: TimeInterval, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

private var application: NSRunningApplication?
private var evidence: URL?
private var expectedBundleID = ""
private var report: [String: Any] = ["status": "failed", "hostLifecycleVerified": false]

do {
    try require(CommandLine.arguments.count == 4,
                "Usage: BackgroundTerminationProbe /absolute/Ghostty.app /new/evidence-directory always|never")
    let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let policy = CommandLine.arguments[3]
    try require(["always", "never"].contains(policy), "Unknown save policy")
    expectedBundleID = Bundle(url: appURL)?.bundleIdentifier ?? ""
    try require(expectedBundleID.hasPrefix("dev.pashifika.ghostty.organization-probe."), "Not a dedicated probe app")
    try require(NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID).isEmpty,
                "The dedicated app is already running")
    try require(!FileManager.default.fileExists(atPath: root.path), "Evidence directory already exists")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    evidence = root
    let defaults = UserDefaults(suiteName: expectedBundleID)!
    try require(defaults.object(forKey: "BackgroundTerminationProbeRun") == nil, "Probe bundle was already used")
    defaults.set(UUID().uuidString, forKey: "BackgroundTerminationProbeRun")
    defaults.set(policy == "always", forKey: "NSQuitAlwaysKeepsWindows")
    try require(defaults.synchronize(), "Cannot set the isolated native save policy")
    let config = root.appendingPathComponent("config.ghostty")
    try """
    window-save-state = \(policy)
    initial-window = false
    quit-after-last-window-closed = false
    confirm-close-surface = always
    auto-update = off
    """.write(to: config, atomically: true, encoding: .utf8)

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    configuration.addsToRecentItems = false
    configuration.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GHOSTTY_") }
    configuration.environment["GHOSTTY_CONFIG_PATH"] = config.path
    configuration.environment["GHOSTTY_USER_DEFAULTS_SUITE"] = expectedBundleID
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        application = app
        launchError = error
    }
    waitFor(10) { application?.isFinishedLaunching == true || launchError != nil }
    if let launchError { throw launchError }
    try require(application?.bundleIdentifier == expectedBundleID && application?.isFinishedLaunching == true,
                "Dedicated app did not finish launching")
    let app = application!
    report["bundleID"] = expectedBundleID
    report["policy"] = policy
    report["pid"] = Int(app.processIdentifier)
    report["activeBeforeQuit"] = app.isActive
    try require(!app.isActive, "App launched in the foreground")
    try require(app.terminate(), "Ordinary quit request was rejected")
    var activated = false
    waitFor(12) {
        activated = activated || app.isActive
        return app.isTerminated
    }
    report["activatedDuringQuit"] = activated
    report["terminatedWithoutActivation"] = app.isTerminated
    try require(app.isTerminated && !activated, "Background app did not quit without activation")
    report["status"] = "passed"
} catch {
    report["error"] = String(describing: error)
    if let app = application, app.bundleIdentifier == expectedBundleID, !app.isTerminated {
        _ = app.activate(options: [])
        waitFor(3) { app.isActive }
        _ = app.terminate()
        waitFor(12) { app.isTerminated }
        report["cleanupTerminated"] = app.isTerminated
        if !app.isTerminated { report["leftRunningPID"] = Int(app.processIdentifier) }
    }
}

let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
if let evidence { try data.write(to: evidence.appendingPathComponent("result.json"), options: .atomic) }
FileHandle.standardOutput.write(data)
print()
exit(report["status"] as? String == "passed" ? 0 : 1)
