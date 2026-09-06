#if DEBUG && os(macOS)
import Cocoa
import Combine

/// Opt-in instrumentation, not an organization store or an alternate restoration path.
/// Run with macos/Probes/NativeRestorationGate.swift in the dedicated probe bundle.
@MainActor
final class NativeRestorationProbe: NSObject {
    static let bundleID = Bundle.main.bundleIdentifier ?? ""
    static let commandNotification = Notification.Name(bundleID + ".restore-command")
    static let shared: NativeRestorationProbe? = {
        guard ProcessInfo.processInfo.environment["GHOSTTY_ORGANIZATION_PROBE"] == "restore" else { return nil }
        return NativeRestorationProbe()
    }()

    private let root: URL
    private let runID: String
    private let phase: String
    private let mode = ProcessInfo.processInfo.environment["GHOSTTY_ORGANIZATION_PROBE_MODE"] ?? "native"
    private var grouped: Bool { mode != "native" }
    private var partial: Bool { mode == "groups-partial" }
    private var disabledRestore: Bool { mode == "groups-never" && phase == "restore" }
    private var seedOrganizationApplied = false
    private let output: FileHandle
    private var sequence = 0
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var lifecycleEvents = Set<String>()
    private var enteredCompletions = Set<UUID>()
    private var finishedRestoreBodies = Set<UUID>()
    private var requests = Set<UUID>()
    private var completedRequests = Set<UUID>()
    private var restoredWindows = Set<ObjectIdentifier>()
    private var pendingFocus = Set<UUID>()
    private var finishedFocus = Set<UUID>()
    private var windowRequests: [ObjectIdentifier: UUID] = [:]
    private var focusTargets: [UUID: Weak<Ghostty.SurfaceView>] = [:]
    private var groupObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var controllerFocus: [ObjectIdentifier: String] = [:]
    private var decodedPWDs: [String: String] = [:]
    private var childSessions: [UUID: [String: Any]] = [:]
    private var runLoopObserver: CFRunLoopObserver?
    private var observationScheduled = false
    private var observationPending = false
    private var lastObservation: Data?
    private var readyWindows: Data?
    private var lateStateChange = false
    private var createdSurfaces: [UUID] = []
    private var decodedSurfaces: [UUID] = []
    private var failures: [String] = []
    private var nativeBarrier = false
    private var seedRequested = false
    private var seedControllers: [TerminalController] = []
    private var seedSelection: Ghostty.SurfaceView?
    private var ready = false
    private var quitPending = false
    private var quitRequested = false

    private override init() {
        let environment = ProcessInfo.processInfo.environment
        guard Self.bundleID.hasPrefix("dev.pashifika.ghostty.organization-probe."),
              let directory = environment["GHOSTTY_ORGANIZATION_PROBE_DIRECTORY"],
              let runID = environment["GHOSTTY_ORGANIZATION_PROBE_RUN"], UUID(uuidString: runID) != nil,
              let phase = environment["GHOSTTY_ORGANIZATION_PROBE_PHASE"], ["seed", "restore"].contains(phase),
              environment["GHOSTTY_USER_DEFAULTS_SUITE"] == Self.bundleID + "." + runID,
              environment["GHOSTTY_CONFIG_PATH"] == URL(fileURLWithPath: directory).appendingPathComponent("config").path,
              environment["GHOSTTY_CLEAR_USER_DEFAULTS"] == nil else {
            preconditionFailure("Native restoration probe requires its dedicated bundle, suite, config and harness directory")
        }
        self.root = URL(fileURLWithPath: directory)
        self.runID = runID
        self.phase = phase
        let log = root.appendingPathComponent(phase + ".jsonl")
        guard !FileManager.default.fileExists(atPath: log.path),
              FileManager.default.createFile(atPath: log.path, contents: nil),
              let output = try? FileHandle(forWritingTo: log) else {
            preconditionFailure("Cannot create native restoration probe log")
        }
        self.output = output
        super.init()
        emit("probeStarted", [
            "bundleID": Bundle.main.bundleIdentifier ?? "", "suite": UserDefaults.ghosttySuite ?? "",
            "config": environment["GHOSTTY_CONFIG_PATH"] ?? "", "arguments": CommandLine.arguments,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "keepWindows": UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows"),
            "ignoreState": UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState")
        ])
        if UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") ||
            !UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows") {
            fail("Native Resume is disabled in the dedicated bundle defaults")
        }
    }

    /// Install before AppKit starts restoration, at entry to applicationWillFinishLaunching.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        if grouped {
            observers.append(center.addObserver(
                forName: TabOrganization.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.observeNativeState(source: "organizationDidChange") }
            })
        }
        // AppKit guarantees all native callbacks were called, even for zero windows.
        observers.append(center.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nativeBarrier = true
                self.emit("nativeRestorationFinished", self.counters())
                if self.requests != self.enteredCompletions { self.fail("Native barrier preceded a tracked callback entry") }
                self.observeNativeState(source: "nativeRestorationFinished")
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didUpdateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeNativeState(source: "applicationDidUpdate") }
        })
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit("applicationWillTerminate", ["orderlyQuitRequested": self.quitRequested])
                try? self.output.synchronize()
            }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow,
                          window.windowController is TerminalController else { return }
                    self.emit("nativeWindowEvent", [
                        "name": name.rawValue, "window": window.windowNumber,
                        "identity": self.identity(window), "selectedTab": window.tabGroup?.selectedWindow.map(self.identity) ?? ""
                    ])
                    self.observeNativeState(source: name.rawValue)
                }
            })
        }
        // Read only after queued publishers and the current lifecycle callback return.
        runLoopObserver = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            guard let self, self.observationPending, !self.observationScheduled else { return }
            self.observationPending = false
            self.checkReadiness()
        }
        if let runLoopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Self.commandNotification,
            object: runID, suspensionBehavior: .deliverImmediately)
        lifecycle("willFinishLaunching")
    }

    func lifecycle(_ name: String) {
        guard lifecycleEvents.insert(name).inserted else { return }
        var fields = counters()
        if let delegate = NSApp.delegate as? AppDelegate {
            fields["initialWindow"] = delegate.ghostty.config.initialWindow
            fields["windowSaveState"] = delegate.ghostty.config.windowSaveState
            fields["configErrors"] = delegate.ghostty.config.errors
        }
        emit(name, fields)
        observeNativeState(source: name)
    }

    func fallbackWindowCreated(_ controller: TerminalController) {
        emit("fallbackWindowCreated", ["window": controller.window?.windowNumber ?? -1])
        fail("An initial-window fallback was created during the isolated restoration gate")
    }

    func nativeRestoreBegan(identifier: NSUserInterfaceItemIdentifier) -> UUID {
        let request = UUID()
        requests.insert(request)
        emit("nativeRestoreBegan", ["request": request.uuidString, "identifier": identifier.rawValue])
        if nativeBarrier { fail("A native restore request arrived after the documented barrier") }
        return request
    }

    /// Observe handoff and return separately: AppKit may notify inside its callback.
    func nativeRestoreWillComplete(_ request: UUID?, window: NSWindow?, error: Error?) {
        guard let request, requests.contains(request), enteredCompletions.insert(request).inserted else {
            fail("Missing or duplicate native restore callback entry")
            return
        }
        if let window {
            windowRequests[ObjectIdentifier(window)] = request
            if !restoredWindows.insert(ObjectIdentifier(window)).inserted {
                fail("The same native window completed two restoration requests")
            }
        }
        emit("nativeRestoreHandedToAppKit", [
            "request": request.uuidString, "window": window?.windowNumber ?? -1,
            "error": error.map(String.init(describing:)) ?? "", "returnedWindow": window != nil
        ])
        if !disabledRestore && (error != nil || window == nil) {
            fail("A native terminal request did not restore a window")
        }
        observeNativeState(source: "nativeRestoreHandedToAppKit")
    }

    func nativeRestoreCompleted(_ request: UUID?, window: NSWindow?, error: Error?) {
        guard let request, enteredCompletions.contains(request), completedRequests.insert(request).inserted else {
            fail("Missing or duplicate native restore callback return")
            return
        }
        emit("nativeRestoreCompleted", [
            "request": request.uuidString, "window": window?.windowNumber ?? -1,
            "error": error.map(String.init(describing:)) ?? "", "returnedWindow": window != nil
        ])
        observeNativeState(source: "nativeRestoreCompleted")
    }

    func nativeRestoreBodyFinished(_ request: UUID?) {
        guard let request, requests.contains(request), finishedRestoreBodies.insert(request).inserted else {
            fail("Missing or duplicate native restore body completion")
            return
        }
        emit("nativeRestoreBodyFinished", ["request": request.uuidString])
        observeNativeState(source: "nativeRestoreBodyFinished")
    }

    func nativeFocusPending(_ request: UUID?, in window: NSWindow, surface: Ghostty.SurfaceView) {
        guard let request, requests.contains(request), pendingFocus.insert(request).inserted else {
            fail("Missing request or duplicate native responder restoration")
            return
        }
        windowRequests[ObjectIdentifier(window)] = request
        focusTargets[request] = .init(surface)
        emit("nativeFocusPending", [
            "request": request.uuidString, "window": window.windowNumber, "surface": surface.id.uuidString
        ])
        observeNativeState(source: "nativeFocusPending")
    }

    /// Covers success, attachment exhaustion, and attachment to the wrong window.
    func nativeFocusFinished(in window: NSWindow, surface: Ghostty.SurfaceView, succeeded: Bool, reason: String) {
        guard let request = windowRequests[ObjectIdentifier(window)], pendingFocus.contains(request),
              focusTargets[request]?.value === surface, finishedFocus.insert(request).inserted else {
            fail("Missing or duplicate native responder completion")
            return
        }
        emit("nativeFocusFinished", [
            "request": request.uuidString, "window": window.windowNumber, "surface": surface.id.uuidString,
            "succeeded": succeeded, "reason": reason, "firstResponderMatches": window.firstResponder === surface,
            "controllerFocusMatches": (window.windowController as? TerminalController)?.focusedSurface === surface,
            "selectedTab": (window.tabGroup?.selectedWindow).map(identity) ?? ""
        ])
        if !succeeded { fail("Native responder restoration failed: " + reason) }
        observeNativeState(source: "nativeFocusFinished")
    }

    /// Hook directly after successful ghostty_surface_new / surfaceModel assignment.
    func surfaceCreated(_ view: Ghostty.SurfaceView) {
        createdSurfaces.append(view.id)
        emit("surfaceCreated", ["surface": view.id.uuidString, "live": view.surface != nil])
        view.$pwd.receive(on: DispatchQueue.main).sink { [weak self, weak view] pwd in
            guard let self, let view else { return }
            self.emit("surfacePWD", ["surface": view.id.uuidString, "pwd": pwd ?? ""])
            self.observeNativeState(source: "surfacePWD")
        }.store(in: &subscriptions)
        view.$surfaceSize.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.observeNativeState(source: "surfaceSize")
        }.store(in: &subscriptions)
        view.$focusInstant.receive(on: DispatchQueue.main).sink { [weak self, weak view] _ in
            guard let self, let view else { return }
            self.emit("surfaceFocusPublished", ["surface": view.id.uuidString, "focused": view.focused])
            self.observeNativeState(source: "surfaceFocusPublished")
        }.store(in: &subscriptions)
        view.$title.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self, weak view] title in
            guard let self, let view else { return }
            self.observeChildSession(view, title: title)
        }.store(in: &subscriptions)
        if ready { fail("A surface was created after the observation snapshot") }
    }

    /// Hook in the native SurfaceView decoder after its real initializer returns.
    func surfaceDecoded(_ view: Ghostty.SurfaceView, savedPWD: String?) {
        decodedSurfaces.append(view.id)
        decodedPWDs[view.id.uuidString] = savedPWD ?? ""
        emit("surfaceDecoded", ["surface": view.id.uuidString, "savedPWD": savedPWD ?? "", "live": view.surface != nil])
    }

    /// Call after TerminalController encodes its native state, never from a sidecar.
    func windowEncoded(_ controller: TerminalController) {
        emit("windowEncoded", windowSnapshot(controller))
    }

    @objc private func command(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.command(notification) }
            return
        }
        switch notification.userInfo?["action"] as? String {
        case "seed": seed()
        case "quit":
            quitPending = true
            scheduleObservation()
        default: fail("Unknown harness command")
        }
    }

    private func seed() {
        guard phase == "seed", !seedRequested, nativeBarrier, TerminalController.all.isEmpty,
              requests.isEmpty, let delegate = NSApp.delegate as? AppDelegate else {
            fail("Seed requested outside a clean first launch")
            return
        }
        seedRequested = true
        guard delegate.ghostty.config.errors.isEmpty, !delegate.ghostty.config.initialWindow,
              delegate.ghostty.config.windowSaveState == "always" else {
            fail("Probe config did not preserve explicit initial-window=false / window-save-state=always")
            return
        }
        func config(_ directory: String) -> Ghostty.SurfaceConfiguration {
            var value = Ghostty.SurfaceConfiguration()
            value.workingDirectory = root.appendingPathComponent(directory).path
            // A global current-config shell command is intentional; base.command
            // stays nil so TerminalController retains normal restore eligibility.
            return value
        }
        let first = TerminalController.newWindow(delegate.ghostty, withBaseConfig: config("a"))
        guard let firstWindow = first.window, let leaf = first.surfaceTree.first,
              let split = first.newSplit(at: leaf, direction: .right, baseConfig: config("b")),
              let second = TerminalController.newTab(delegate.ghostty, from: firstWindow, withBaseConfig: config("c")) else {
            fail("Native first-launch fixture creation failed")
            return
        }
        seedControllers = [first, second]
        seedSelection = split
        emit("seedCreated", ["baseCommandOverride": false, "surfaceCount": createdSurfaces.count])
        if grouped {
            guard let third = TerminalController.newTab(delegate.ghostty, from: firstWindow, withBaseConfig: config("d")),
                  let fourth = TerminalController.newTab(delegate.ghostty, from: firstWindow, withBaseConfig: config("e")) else {
                fail("Grouped first-launch native fixture creation failed")
                return
            }
            seedControllers += [third, fourth]
        }
        // This orders ordinary first-launch actions after their own queued show calls;
        // it is not a restoration barrier or an elapsed-time heuristic.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.grouped {
                self.seedOrganizationApplied = self.seedOrganization()
                if !self.seedOrganizationApplied { self.fail("Semantic organization fixture creation failed") }
            }
            firstWindow.tabGroup?.selectedWindow = firstWindow
            firstWindow.makeKeyAndOrderFront(nil)
            first.focusSurface(split)
            if self.partial {
                // Retain a genuine completed snapshot before native eligibility
                // changes, so the harness can exercise a stale sidecar on restart.
                TabOrganization.shared.flush()
                guard let data = UserDefaults.ghostty.data(forKey: TabOrganizationStore.key) else {
                    self.fail("Missing completed organization snapshot before native omission")
                    return
                }
                self.emit("partialSavedMetadata", [
                    "key": TabOrganizationStore.key,
                    "data": data.base64EncodedString()
                ])
                second.window?.isRestorable = false
                self.emit("partialNativeMemberOmitted", ["identity": second.window.map(self.identity) ?? ""])
            }
            self.observeNativeState(source: "seedSelection")
        }
    }

    private func seedOrganization() -> Bool {
        guard seedControllers.count == 4,
              let window = seedControllers[0].window as? TerminalWindow else { return false }
        let organization = TabOrganization.shared
        let first = seedControllers[0].organizationIdentity.tabID
        let second = seedControllers[1].organizationIdentity.tabID
        let third = seedControllers[2].organizationIdentity.tabID
        guard organization.createGroup(from: first, name: "Project", in: window),
              let firstGroup = organization.presentation(for: window).groups.first(where: {
                  $0.tabs.contains(where: { $0.id == first })
              })?.id,
              organization.moveTab(second, to: firstGroup, index: nil, in: window),
              organization.createGroup(from: third, name: "Project", in: window),
              let secondGroup = organization.presentation(for: window).groups.first(where: {
                  $0.tabs.contains(where: { $0.id == third })
              })?.id else { return false }
        organization.perform(.setGroupColor(groupID: firstGroup, color: .blue), in: window)
        organization.perform(.setGroupColor(groupID: secondGroup, color: .red), in: window)
        (seedControllers[0].window as? TerminalWindow)?.tabColor = .green
        (seedControllers[2].window as? TerminalWindow)?.tabColor = .purple
        guard organization.moveTab(first, to: firstGroup, index: 1, in: window),
              organization.moveGroup(secondGroup, index: 0, in: window) else { return false }
        emit("organizationSeeded", ["firstGroup": firstGroup.uuidString, "secondGroup": secondGroup.uuidString])
        return true
    }

    private func checkReadiness() {
        recordControllerFocus(source: "runLoopBeforeWaiting")
        let controllers = TerminalController.all
        let surfaces = controllers.flatMap { Array($0.surfaceTree) }
        var waiting: [String] = []
        if !nativeBarrier { waiting.append("native app-wide barrier") }
        if !lifecycleEvents.contains("didFinishLaunching") { waiting.append("didFinishLaunching") }
        if !lifecycleEvents.contains("firstActivation") { waiting.append("firstActivation") }
        if waiting.isEmpty, lifecycleEvents.insert("startupObserved").inserted {
            emit("startupObserved", counters())
        }
        if phase == "seed" {
            if grouped && !seedOrganizationApplied { waiting.append("semantic organization seed") }
            if seedControllers.count != (grouped ? 4 : 2) || seedSelection == nil {
                waiting.append("seed creation")
            } else if let first = seedControllers.first, let window = first.window, let selection = seedSelection {
                if window.tabGroup?.windows.count != seedControllers.count || window.tabGroup?.selectedWindow !== window ||
                    window.firstResponder !== selection || first.focusedSurface !== selection {
                    waiting.append("seed input propagation")
                }
            } else {
                waiting.append("seed window")
            }
        } else {
            // Await only work requested by AppKit, never saved membership or selection.
            if requests != completedRequests { waiting.append("native callback returns") }
            if requests != finishedRestoreBodies { waiting.append("native restore bodies") }
            if pendingFocus != finishedFocus { waiting.append("native focus bodies") }
            for (request, target) in focusTargets {
                guard let surface = target.value, let window = surface.window,
                      windowRequests[ObjectIdentifier(window)] == request,
                      window.firstResponder === surface,
                      (window.windowController as? TerminalController)?.focusedSurface === surface else {
                    waiting.append("controller/responder agreement for " + request.uuidString)
                    continue
                }
            }
        }
        for view in surfaces {
            if view.surface == nil || view.window == nil { waiting.append("live attachment for " + view.id.uuidString) }
            if (view.pwd ?? "").isEmpty { waiting.append("terminal PWD for " + view.id.uuidString) }
            if childSessions[view.id] == nil { waiting.append("child handshake for " + view.id.uuidString) }
        }
        for controller in controllers {
            if let group = controller.window?.tabGroup, group.selectedWindow == nil {
                waiting.append("native selected window")
            }
        }
        if grouped, TabOrganization.shared.isRestoring {
            waiting.append("organization reconciliation completion")
        }
        let windows = controllers.map(windowSnapshot).sorted {
            ($0["identity"] as? String ?? "") < ($1["identity"] as? String ?? "")
        }
        var fields = counters()
        fields["windows"] = windows
        fields["focusRequests"] = focusSnapshot()
        fields["sessions"] = childSessions.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { childSessions[$0] }
        fields["decodedPWDs"] = decodedPWDs
        fields["waitingFor"] = waiting.sorted()
        fields["failures"] = failures
        fields["boundary"] = "main-queue delivery followed by CFRunLoop.beforeWaiting"
        if grouped {
            fields["organizationRestoring"] = TabOrganization.shared.isRestoring
            if let data = UserDefaults.ghostty.data(forKey: TabOrganizationStore.key) {
                do {
                    fields["organizationStore"] = try JSONSerialization.jsonObject(with: data)
                } catch {
                    fail("Organization snapshot is not valid encoded data: " + String(describing: error))
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), data != lastObservation {
            lastObservation = data
            emit("stateObserved", fields)
        }
        let windowData = try? JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])
        if ready, !quitRequested, windowData != readyWindows, !lateStateChange {
            lateStateChange = true
            emit("postObservationStateChanged", fields)
            fail("Live state changed after the observational boundary")
        }
        if !ready, waiting.isEmpty, !observationScheduled {
            ready = true
            readyWindows = windowData
            emit(phase == "seed" ? "seedReady" : "restoreObserved", fields)
            if phase == "seed" {
                for controller in controllers {
                    controller.invalidateRestorableState()
                    controller.window?.invalidateRestorableState()
                }
                NSApp.invalidateRestorableState()
            }
        }
        if quitPending, !observationScheduled {
            quitPending = false
            quitRequested = true
            emit("preQuitObserved", fields)
            emit("orderlyQuitRequested", counters())
            // Use normal save/termination, including after a failed gate.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func scheduleObservation() {
        observationPending = true
        guard !observationScheduled else { return }
        observationScheduled = true
        DispatchQueue.main.async { [weak self] in self?.observationScheduled = false }
    }

    private func observeNativeState(source: String) {
        let focusChanged = recordControllerFocus(source: source)
        var groupsChanged = false
        var groups: [ObjectIdentifier: NSWindowTabGroup] = [:]
        for controller in TerminalController.all {
            if let group = controller.window?.tabGroup { groups[ObjectIdentifier(group)] = group }
        }
        for key in Array(groupObservations.keys) where groups[key] == nil {
            groupObservations.removeValue(forKey: key)
            groupsChanged = true
        }
        for (key, group) in groups where groupObservations[key] == nil {
            groupsChanged = true
            groupObservations[key] = [
                group.observe(\.selectedWindow, options: [.old, .new]) { [weak self] group, change in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.emit("nativeSelectionChanged", [
                            "group": String(describing: ObjectIdentifier(group)),
                            "previous": (change.oldValue ?? nil).map(self.identity) ?? "",
                            "selectedTab": group.selectedWindow.map(self.identity) ?? "",
                            "tabOrder": group.windows.map(self.identity)
                        ])
                        self.recordControllerFocus(source: "nativeSelectionChanged")
                        self.scheduleObservation()
                    }
                },
                group.observe(\.windows, options: [.new]) { [weak self] group, _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.emit("nativeTabOrderChanged", [
                            "group": String(describing: ObjectIdentifier(group)),
                            "selectedTab": group.selectedWindow.map(self.identity) ?? "",
                            "tabOrder": group.windows.map(self.identity)
                        ])
                        self.recordControllerFocus(source: "nativeTabOrderChanged")
                        self.scheduleObservation()
                    }
                }
            ]
            emit("nativeGroupObserved", [
                "group": String(describing: key), "selectedTab": group.selectedWindow.map(identity) ?? "",
                "tabOrder": group.windows.map(identity)
            ])
        }
        // An unchanged update must not enqueue another update indefinitely.
        if source != "applicationDidUpdate" || focusChanged || groupsChanged { scheduleObservation() }
    }

    @discardableResult
    private func recordControllerFocus(source: String) -> Bool {
        // focusedSurface is not @Published/KVO. Read on existing focus and lifecycle events.
        var changed = false
        for controller in TerminalController.all {
            let key = ObjectIdentifier(controller)
            let focused = controller.focusedSurface?.id.uuidString ?? ""
            guard controllerFocus[key] != focused else { continue }
            var fields = windowSnapshot(controller)
            fields["previous"] = controllerFocus[key] ?? ""
            fields["source"] = source
            controllerFocus[key] = focused
            changed = true
            emit("controllerFocusChanged", fields)
        }
        return changed
    }

    private func focusSnapshot() -> [[String: Any]] {
        focusTargets.keys.sorted { $0.uuidString < $1.uuidString }.map { request in
            let surface = focusTargets[request]?.value
            let window = surface?.window
            let controller = window?.windowController as? TerminalController
            return [
                "request": request.uuidString, "surface": surface?.id.uuidString ?? "",
                "bodyFinished": finishedFocus.contains(request),
                "firstResponder": (window?.firstResponder as? Ghostty.SurfaceView)?.id.uuidString ?? "",
                "focusedSurface": controller?.focusedSurface?.id.uuidString ?? "",
                "selectedTab": (window?.tabGroup?.selectedWindow).map(identity) ?? ""
            ]
        }
    }

    private func observeChildSession(_ view: Ghostty.SurfaceView, title: String) {
        let prefix = "ghostty-native-session:" + runID + ":" + phase + ":"
        guard title.hasPrefix(prefix) else { return }
        let nonce = String(title.dropFirst(prefix.count))
        guard UUID(uuidString: nonce) != nil else {
            fail("Invalid child-session title nonce")
            return
        }
        if let session = childSessions[view.id] {
            if session["nonce"] as? String != nonce { fail("A surface reported two child sessions") }
            return
        }
        do {
            let path = root.appendingPathComponent("sessions/" + phase + "/" + nonce)
            let fields = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
            guard fields.count == 5, fields[0] == runID, fields[1] == phase,
                  let pid = Int(fields[2]), pid > 0, fields[3] == nonce, fields[4].hasPrefix("/") else {
                fail("Invalid child-session handshake")
                return
            }
            guard !childSessions.values.contains(where: { $0["nonce"] as? String == nonce }) else {
                fail("Two surfaces reported the same child session")
                return
            }
            let session: [String: Any] = [
                "surface": view.id.uuidString, "run": runID, "phase": phase,
                "pid": pid, "nonce": nonce, "pwd": fields[4]
            ]
            childSessions[view.id] = session
            emit("childSessionObserved", session)
            observeNativeState(source: "childSessionObserved")
        } catch {
            fail("Cannot read the child-session handshake: " + String(describing: error))
        }
    }

    private func counters() -> [String: Any] {
        ["requests": requests.count, "callbackEntries": enteredCompletions.count,
         "completions": completedRequests.count, "finishedRestoreBodies": finishedRestoreBodies.count,
         "restoredWindows": restoredWindows.count, "pendingFocus": pendingFocus.count,
         "finishedFocus": finishedFocus.count, "createdSurfaces": createdSurfaces.count,
         "decodedSurfaces": decodedSurfaces.count, "childSessions": childSessions.count,
         "nativeBarrier": nativeBarrier]
    }

    private func identity(_ window: NSWindow) -> String {
        (window.windowController as? TerminalController)?.surfaceTree.first?.id.uuidString ?? ""
    }

    private func windowSnapshot(_ controller: TerminalController) -> [String: Any] {
        guard let window = controller.window else { return ["missingWindow": true] }
        var snapshot: [String: Any] = [
            "window": window.windowNumber, "identity": identity(window), "restorable": window.isRestorable,
            "tabColor": (window as? TerminalWindow)?.tabColor.rawValue ?? 0,
            "restorationClass": window.restorationClass.map { String(describing: $0) } ?? "",
            "tabOrder": (window.tabGroup?.windows ?? [window]).map(identity),
            "selectedTab": (window.tabGroup?.selectedWindow).map(identity) ?? identity(window),
            "focusedSurface": controller.focusedSurface?.id.uuidString ?? "",
            "firstResponder": (window.firstResponder as? Ghostty.SurfaceView)?.id.uuidString ?? "",
            "tree": controller.surfaceTree.root.map(treeSnapshot) ?? [:],
            "surfaces": controller.surfaceTree.map { view in
                ["id": view.id.uuidString, "pwd": view.pwd ?? "", "live": view.surface != nil,
                 "attached": view.window === window] as [String: Any]
            }
        ]
        if grouped {
            snapshot["organizationTabID"] = controller.organizationIdentity.tabID.uuidString
            snapshot["organizationWindowID"] = controller.organizationIdentity.windowID.uuidString
            if let window = window as? TerminalWindow, !TabOrganization.shared.isRestoring {
                let presentation = TabOrganization.shared.presentation(for: window)
                snapshot["organization"] = [
                    "windowID": presentation.windowID.uuidString,
                    "selectedTabID": presentation.selectedTabID?.uuidString ?? "",
                    "activeGroupID": presentation.activeGroupID?.uuidString ?? "",
                    "groups": presentation.groups.map { group in
                        ["id": group.id.uuidString, "name": group.name, "color": group.color.rawValue,
                         "tabs": group.tabs.map { $0.id.uuidString }] as [String: Any]
                    },
                    "unassigned": presentation.unassigned.map { $0.id.uuidString }
                ] as [String: Any]
            }
        }
        return snapshot
    }

    private func treeSnapshot(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> [String: Any] {
        switch node {
        case .leaf(let view): return ["leaf": view.id.uuidString]
        case .split(let split):
            return ["direction": String(describing: split.direction), "ratio": split.ratio,
                    "left": treeSnapshot(split.left), "right": treeSnapshot(split.right)]
        }
    }

    private func fail(_ reason: String) {
        failures.append(reason)
        emit("failure", ["reason": reason])
    }

    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        sequence += 1
        var record = fields
        record["event"] = event
        record["sequence"] = sequence
        record["run"] = runID
        record["phase"] = phase
        record["pid"] = ProcessInfo.processInfo.processIdentifier
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            try output.write(contentsOf: data)
        } catch {
            preconditionFailure("Cannot write native restoration evidence: \(error)")
        }
    }
}
#endif
