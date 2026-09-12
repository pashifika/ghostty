import Cocoa
import Testing
@testable import Ghostty

@MainActor
struct TerminalRestorationTests {
    @Test func unknownDisplayDirectoryRetainsTheLatestStartupCandidate() throws {
        let view = try surface(directory: "/tmp/initial")
        view.pwd = nil
        #expect(try savedDirectory(view) == "/tmp/initial")

        view.pwd = "/tmp/latest"
        view.pwd = ""
        #expect(view.pwd == "")
        #expect(try savedDirectory(view) == "/tmp/latest")

        view.pwd = nil
        #expect(view.pwd == nil)
        #expect(try savedDirectory(view) == "/tmp/latest")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        view.pwd = home
        view.pwd = ""
        #expect(try savedDirectory(view) == home)
    }

    @Test func decodedDirectorySurvivesBeforeTheFirstShellReport() throws {
        let saved = "/tmp/restored"
        let view = try decodedSurface(directory: saved)
        view.pwd = ""
        #expect(try savedDirectory(view) == saved)
        view.pwd = "/tmp/observed"
        #expect(try savedDirectory(view) == "/tmp/observed")
    }

    @Test(arguments: [nil, ""] as [String?])
    func legacyUnknownDirectoriesDoNotInventASavedHome(directory: String?) throws {
        let view = try decodedSurface(directory: directory)
        #expect(try savedDirectory(view) == nil)
        view.pwd = "/tmp/first-report"
        #expect(try savedDirectory(view) == "/tmp/first-report")
    }

    @Test func nativeEncodingUsesPreparedValuesUntilCancellation() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let left = try surface(directory: "/tmp/left")
        let right = try surface(directory: "/tmp/right")
        let tree = try SplitTree(view: left).inserting(view: right, at: left, direction: .right)
        let controller = WindowlessTerminalController(delegate.ghostty, withSurfaceTree: tree)
        controller.focusedSurface = right
        controller.titleOverride = "Captured title"
        let identity = controller.organizationIdentity
        try controller.prepareRestorableState()

        left.pwd = "/tmp/new-left"
        right.pwd = ""
        controller.surfaceTree = .init(view: left)
        controller.focusedSurface = left
        controller.titleOverride = "New title"
        controller.organizationIdentity = .init(tabID: UUID(), windowID: UUID())
        try controller.prepareRestorableState()

        let prepared = try nativeRoundTrip(controller)
        #expect(try directories(prepared) == [left.id: "/tmp/left", right.id: "/tmp/right"])
        #expect(prepared.focusedSurface == right.id.uuidString)
        #expect(prepared.titleOverride == "Captured title")
        #expect(prepared.organizationIdentity == identity)

        controller.clearPreparedRestorableState()
        let current = try nativeRoundTrip(controller)
        #expect(try directories(current) == [left.id: "/tmp/new-left"])
        #expect(current.focusedSurface == left.id.uuidString)
        #expect(current.titleOverride == "New title")
        #expect(current.organizationIdentity == controller.organizationIdentity)
    }

    private func surface(directory: String) throws -> Ghostty.SurfaceView {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let app = try #require(delegate.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory
        config.command = "/usr/bin/true"
        config.waitAfterCommand = true
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func decodedSurface(directory: String?) throws -> Ghostty.SurfaceView {
        let fixture: [String: Any] = [
            "uuid": UUID().uuidString,
            "pwd": directory.map { $0 as Any } ?? NSNull()
        ]
        return try JSONDecoder().decode(
            Ghostty.SurfaceView.self,
            from: JSONSerialization.data(withJSONObject: fixture))
    }

    private struct SavedDirectory: Decodable {
        let pwd: String?
    }

    private func savedDirectory(_ view: Ghostty.SurfaceView) throws -> String? {
        try JSONDecoder().decode(SavedDirectory.self, from: JSONEncoder().encode(view)).pwd
    }

    private func directories(_ state: TerminalRestorableState) throws -> [UUID: String] {
        try Dictionary(uniqueKeysWithValues: state.surfaceTree.map { view in
            (view.id, try #require(try savedDirectory(view)))
        })
    }

    private func nativeRoundTrip(_ controller: TerminalController) throws -> TerminalRestorableState {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        defer { window.close() }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(window, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
        if let error = archiver.error { throw error }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        #expect(unarchiver.decodeInteger(forKey: TerminalRestorableState.versionKey) == 7)
        return try #require(TerminalRestorableState(coder: unarchiver))
    }
}

private class WindowlessTerminalController: TerminalController {
    // Exercise native encoding without registering windows or writing organization state.
    override var window: NSWindow? {
        get { nil }
        set { precondition(newValue == nil) }
    }
}
