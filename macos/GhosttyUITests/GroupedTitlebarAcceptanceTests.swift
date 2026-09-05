import XCTest

final class GroupedTitlebarAcceptanceTests: GhosttyCustomConfigCase {
    @MainActor
    func testGroupNavigationAndLastMemberUndo() throws {
        let app = try launchGrouped()
        defer { app.terminate() }
        try nameTab("Alpha", in: app)
        try createGroup("First", from: "Alpha", in: app)
        app.typeKey("d", modifierFlags: .command)
        try nameTab("Split Leaf", in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tab("Alpha", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(header("First", in: app).exists)
        app.typeKey("t", modifierFlags: .command)
        try nameTab("Beta", in: app)
        XCTAssertTrue(tab("Alpha", in: app).exists)
        try createGroup("Second", from: "Beta", in: app)
        XCTAssertTrue(tab("Alpha", in: app).waitForNonExistence(timeout: 5))
        header("First", in: app).click()
        XCTAssertTrue(tab("Alpha", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(tab("Beta", in: app).waitForNonExistence(timeout: 5))
        app.typeText("printf '\\033]0;Alpha Focused\\007'\n")
        XCTAssertTrue(tab("Alpha Focused", in: app).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(header("First", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(tab("Beta", in: app).waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(header("First", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(header("Second", in: app).exists)
        header("First", in: app).click()
        app.typeText("printf '\\033]0;Undo Survivor\\007'\n")
        XCTAssertTrue(tab("Undo Survivor", in: app).waitForExistence(timeout: 5))
        capture("Grouped navigation and native Undo", app: app)
    }

    @MainActor
    func testDeletionCheckboxCancellationAndKeepTabs() throws {
        let app = try launchTwoMembers()
        defer { app.terminate() }
        try openDeletion(in: app)
        let checkbox = app.sheets.checkBoxes["Also close tabs"].firstMatch
        XCTAssertEqual(checkbox.value as? Int, 0)
        checkbox.click()
        XCTAssertEqual(checkbox.value as? Int, 1)
        XCTAssertTrue(tab("Alpha", in: app).exists)
        XCTAssertTrue(tab("Beta", in: app).exists)
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(header("Project", in: app).exists)
        try openDeletion(in: app)
        XCTAssertEqual(checkbox.value as? Int, 0)
        app.sheets.buttons["Delete Group"].firstMatch.click()
        XCTAssertTrue(header("Project", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(tab("Alpha", in: app).exists)
        XCTAssertTrue(tab("Beta", in: app).exists)
        app.typeText("printf '\\033]0;Kept Selected\\007'\n")
        XCTAssertTrue(tab("Kept Selected", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(tab("Alpha", in: app).exists)
        capture("Group-only deletion retains live tabs and selection", app: app)
    }

    @MainActor
    func testCheckedDeletionStopsAfterCanceledProtectedClose() throws {
        let app = try launchTwoMembers(confirmation: "always")
        defer { app.terminate() }
        try openDeletion(in: app)
        app.sheets.checkBoxes["Also close tabs"].firstMatch.click()
        app.sheets.buttons["Delete Group"].firstMatch.click()
        let close = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(tab("Alpha", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(header("Project", in: app).exists)
        XCTAssertTrue(tab("Beta", in: app).exists)
        app.typeText("printf '\\033]0;Canceled Survivor\\007'\n")
        XCTAssertTrue(tab("Canceled Survivor", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(header("Project", in: app).exists)
        capture("Partial group closure retains the canceled member", app: app)
        try openDeletion(in: app)
        app.sheets.checkBoxes["Also close tabs"].firstMatch.click()
        app.sheets.buttons["Delete Group"].firstMatch.click()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(header("Project", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 0, timeout: 5))
    }

    @MainActor
    func testHiddenCloseButtonsReloadAndFullscreenContextClose() throws {
        let app = try launchTwoMembers()
        defer { app.terminate() }
        tab("Beta", in: app).rightClick()
        let menus = app.windows.menus
        menus.menuItems["Move to Group"].firstMatch.hover()
        let unassigned = menus.menuItems["Unassigned"].firstMatch
        XCTAssertTrue(unassigned.waitForExistence(timeout: 5))
        unassigned.click()
        header("Project", in: app).click()
        XCTAssertTrue(app.buttons["Close Alpha"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Beta"].firstMatch.exists)
        let originalConfig = try String(contentsOf: XCTUnwrap(configFile), encoding: .utf8)
        try updateConfig(originalConfig + "\nmacos-tab-close-button = false\n")
        app.typeKey(",", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Close Alpha"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Beta"].firstMatch.waitForNonExistence(timeout: 5))
        let windowedFrame = app.windows.firstMatch.frame
        app.typeKey("f", modifierFlags: [.command, .control])
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).hover()
        tab("Beta", in: app).rightClick()
        let close = app.windows.menus.menuItems["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, windowedFrame.width)
        capture("Native fullscreen context Close with x hidden", app: app, fullScreen: true)
        close.click()
        XCTAssertTrue(tab("Beta", in: app).waitForNonExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(app.wait(for: \.windows.firstMatch.frame, toEqual: windowedFrame, timeout: 5))
        app.typeText("printf '\\033]0;Fullscreen Survivor\\007'\n")
        XCTAssertTrue(tab("Fullscreen Survivor", in: app).waitForExistence(timeout: 5))
        try updateConfig(originalConfig)
        app.typeKey(",", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Close Fullscreen Survivor"].firstMatch.waitForExistence(timeout: 5))
        capture("Close buttons restored without replacing the selected terminal", app: app)
    }

    @MainActor
    func testUnassignedCloseVisibilityAndLegacyStyleReload() throws {
        let app = try launchGrouped()
        defer { app.terminate() }
        try nameTab("Unassigned", in: app)
        let config = try String(contentsOf: XCTUnwrap(configFile), encoding: .utf8)
        try updateConfig(config + "\nmacos-tab-close-button = false\n")
        app.typeKey(",", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Close Unassigned"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.buttons["_XCUI:CloseWindow"].isHittable)
        capture("Unassigned-only strip with hidden x and native window controls", app: app)
        try updateConfig(config + "\nmacos-tab-close-button = false\nmacos-titlebar-style = native\n")
        app.typeKey(",", modifierFlags: [.command, .shift])
        try nameTab("Existing Grouped Window", in: app)
        app.typeKey("n", modifierFlags: .command)
        app.typeText("printf '\\033]0;Legacy One\\007'\n")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("printf '\\033]0;Legacy Two\\007'\n")
        XCTAssertTrue(app.windows.firstMatch.tabs["Legacy Two"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.firstMatch.toolbars.tabs.count, 0)
        app.windows.firstMatch.tabs["Legacy One"].hover()
        capture("Legacy native tabs retain their own close buttons when the custom option is false", app: app)
        app.typeKey("w", modifierFlags: .command)
        app.typeText("printf '\\033]0;Legacy Survivor\\007'\n")
        XCTAssertTrue(app.windows["Legacy Survivor"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(tab("Existing Grouped Window", in: app).exists)
    }

    @MainActor
    func testKeyboardOrganizationKeepsTerminalInputUsable() throws {
        let app = try launchGrouped()
        defer { app.terminate() }
        try nameTab("Keyboard Tab", in: app)
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey("\r", modifierFlags: .control)
        XCTAssertTrue(app.windows.menus.menuItems["Create Group..."].firstMatch.waitForExistence(timeout: 5))
        app.typeText("Create Group")
        app.typeKey("\r", modifierFlags: [])
        let field = app.sheets.textFields["Group name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Keyboard Group")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(header("Keyboard Group", in: app).waitForExistence(timeout: 5))
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey("\r", modifierFlags: .control)
        XCTAssertTrue(app.windows.menus.menuItems["Rename Group..."].firstMatch.waitForExistence(timeout: 5))
        app.typeText("Rename Group")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Keyboard Renamed")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(header("Keyboard Renamed", in: app).waitForExistence(timeout: 5))
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(tab("Keyboard Tab", in: app).exists)
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.sheets.checkBoxes["Also close tabs"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(header("Keyboard Renamed", in: app).exists)
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey("\r", modifierFlags: .control)
        app.typeText("Move to Group")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.windows.menus.menuItems["Unassigned"].firstMatch.waitForExistence(timeout: 5))
        app.typeText("Unassigned")
        app.typeKey("\r", modifierFlags: [])
        XCTAssertTrue(header("Keyboard Renamed", in: app).waitForNonExistence(timeout: 5))
        app.menuItems["Focus Tab Groups"].firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
        try nameTab("Keyboard Input Survived", in: app)
    }

    @MainActor
    func testEqualNamedGroupMergeAndLastMemberNativeTearOff() throws {
        let app = try launchGrouped()
        defer { app.terminate() }
        try nameTab("Alpha", in: app)
        try createGroup("Project", from: "Alpha", in: app)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5))
        try nameTab("Beta", in: app)
        try createGroup("Project", from: "Beta", in: app)
        app.menuItems["mergeAllWindows:"].firstMatch.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 1, timeout: 5))
        XCTAssertEqual(app.toolbars.disclosureTriangles.matching(identifier: "Project").count, 2)
        app.typeKey("1", modifierFlags: .command)
        try nameTab("Merged Selected", in: app)
        app.typeText("export GHOSTTY_GROUP_SMOKE=native-survivor\n")
        tab("Merged Selected", in: app).rightClick()
        let move = app.windows.menus.menuItems["Move Tab to New Window"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5))
        XCTAssertEqual(app.windows.firstMatch.toolbars.disclosureTriangles.count, 0)
        XCTAssertEqual(app.toolbars.disclosureTriangles.matching(identifier: "Project").count, 1)
        app.typeText("printf '\\033]0;%s\\007' \"$GHOSTTY_GROUP_SMOKE\"\n")
        XCTAssertTrue(tab("native-survivor", in: app).waitForExistence(timeout: 5))
        capture("Native tear-off preserves the shell and removes its last-member group", app: app)
    }

    @MainActor
    func testCollapsedHeaderDropsAndTrailingGroupClamp() throws {
        let app = try launchTwoMembers()
        defer { app.terminate() }
        try createGroup("Second", from: "Beta", in: app)
        app.typeKey("t", modifierFlags: .command)
        try nameTab("Gamma", in: app)
        tab("Gamma", in: app).rightClick()
        app.windows.menus.menuItems["Move to Group"].firstMatch.hover()
        app.windows.menus.menuItems["Unassigned"].firstMatch.click()
        header("Second", in: app).click()
        tab("Beta", in: app).press(forDuration: 0.2, thenDragTo: header("Project", in: app))
        XCTAssertTrue(header("Second", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(tab("Alpha", in: app).exists)
        XCTAssertTrue(tab("Beta", in: app).exists)
        try createGroup("Second", from: "Beta", in: app)
        let beyondUnassigned = tab("Gamma", in: app)
            .coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 10, dy: 0))
        header("Project", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: beyondUnassigned)
        XCTAssertLessThan(header("Second", in: app).frame.minX, header("Project", in: app).frame.minX)
        XCTAssertLessThan(header("Project", in: app).frame.minX, tab("Gamma", in: app).frame.minX)
        tab("Gamma", in: app).press(forDuration: 0.2, thenDragTo: header("Second", in: app))
        try nameTab("Background Drop Kept Selection", in: app)
        XCTAssertTrue(tab("Gamma", in: app).exists)
        XCTAssertTrue(tab("Alpha", in: app).waitForNonExistence(timeout: 5))
        capture("Collapsed-header drops and the fixed trailing unassigned region", app: app)
    }

    @MainActor
    func testOverflowRevealsNativeKeyboardSelectionAndRetainsFullNames() throws {
        let app = try launchGrouped()
        defer { app.terminate() }
        try nameTab("Terminal 1", in: app)
        let name = "A deliberately long project name retained beyond the visible titlebar label"
        try createGroup(name, from: "Terminal 1", in: app)
        for index in 2...8 {
            app.toolbars.buttons["New Tab"].firstMatch.click()
            try nameTab("Terminal \(index)", in: app)
        }
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        let titlebarGrip = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -6, dy: 20))
        titlebarGrip.press(forDuration: 0.1, thenDragTo: titlebarGrip.withOffset(CGVector(dx: -80, dy: 60)))
        XCTAssertGreaterThan(abs(window.frame.origin.x - origin.x), 40)
        XCTAssertGreaterThan(abs(window.frame.origin.y - origin.y), 30)
        let width = window.frame.width
        let resizeGrip = window.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.8))
        resizeGrip.press(forDuration: 0.1, thenDragTo: resizeGrip.withOffset(CGVector(dx: -120, dy: 0)))
        XCTAssertLessThan(window.frame.width, width - 60)
        let newTab = app.toolbars.buttons["New Tab"].firstMatch
        XCTAssertTrue(newTab.isHittable)
        XCTAssertLessThan(window.frame.maxX - newTab.frame.maxX, 30)
        XCTAssertEqual(app.toolbars.scrollBars.count, 0)
        XCTAssertTrue(app.toolbars.buttons["Scroll tabs left"].firstMatch.exists)
        XCTAssertTrue(tab("Terminal 8", in: app).isHittable)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(tab("Terminal 1", in: app).isHittable)
        XCTAssertTrue(app.toolbars.buttons["Scroll tabs right"].firstMatch.exists)
        capture("Long full-name group label and horizontally overflowing single row", app: app)
        header(name, in: app).rightClick()
        app.windows.menus.menuItems["Rename Group..."].firstMatch.click()
        let field = app.sheets.textFields["Group name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name)
        app.sheets.buttons["Cancel"].firstMatch.click()
        app.typeText("printf '\\033]0;First Selected\\007'\n")
        XCTAssertTrue(tab("First Selected", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackgroundContextRenameCloseAndValidation() throws {
        let app = try launchTwoMembers()
        defer { app.terminate() }
        tab("Alpha", in: app).rightClick()
        let menu = app.windows.firstMatch.menus.firstMatch
        menu.menuItems["Rename Tab..."].firstMatch.click()
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Alpha")
        field.typeText("Renamed Alpha")
        app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertTrue(tab("Renamed Alpha", in: app).waitForExistence(timeout: 5))
        tab("Beta", in: app).click()
        tab("Renamed Alpha", in: app).rightClick()
        XCTAssertTrue(menu.menuItems["Close Tabs to the Right"].firstMatch.isEnabled)
        menu.menuItems["Close"].firstMatch.click()
        XCTAssertTrue(tab("Renamed Alpha", in: app).waitForNonExistence(timeout: 5))
        tab("Beta", in: app).rightClick()
        XCTAssertFalse(menu.menuItems["Close Other Tabs"].firstMatch.isEnabled)
        XCTAssertFalse(menu.menuItems["Close Tabs to the Right"].firstMatch.isEnabled)
        XCTAssertFalse(menu.menuItems["Move Tab to New Window"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        try nameTab("Shared Menu Survivor", in: app)
        capture("Shared native menu targets and one-tab validation", app: app)
    }

    @MainActor
    private func launchGrouped(confirmation: String = "false") throws -> XCUIApplication {
        try updateConfig("""
        macos-titlebar-style = groups
        window-save-state = never
        confirm-close-surface = \(confirmation)
        shell-integration = none
        command = /bin/sh
        auto-update = off
        window-title-font-family = Menlo
        """)
        let app = try ghosttyApplication(defaultsSuite: "GhosttyGroupedAcceptance." + UUID().uuidString)
        app.launchEnvironment["ENV"] = ""
        app.launchEnvironment["BASH_ENV"] = ""
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launchTwoMembers(confirmation: String = "false") throws -> XCUIApplication {
        let app = try launchGrouped(confirmation: confirmation)
        try nameTab("Alpha", in: app)
        try createGroup("Project", from: "Alpha", in: app)
        app.typeKey("t", modifierFlags: .command)
        try nameTab("Beta", in: app)
        XCTAssertTrue(tab("Alpha", in: app).exists)
        return app
    }

    @MainActor
    private func nameTab(_ title: String, in app: XCUIApplication) throws {
        app.typeText("printf '\\033]0;\(title)\\007'\n")
        XCTAssertTrue(tab(title, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(tab(title, in: app).isEnabled)
    }

    @MainActor
    private func createGroup(_ name: String, from title: String, in app: XCUIApplication) throws {
        tab(title, in: app).rightClick()
        let create = app.windows.firstMatch.menus.firstMatch.menuItems["Create Group..."].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.click()
        let field = app.sheets.textFields["Group name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.sheets.buttons["Save"].firstMatch.click()
        XCTAssertTrue(header(name, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func openDeletion(in app: XCUIApplication) throws {
        header("Project", in: app).rightClick()
        let delete = app.windows.firstMatch.menus.firstMatch.menuItems["Delete Group..."].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(app.sheets.checkBoxes["Also close tabs"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func tab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.toolbars.tabs[title].firstMatch
    }

    @MainActor
    private func header(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.toolbars.disclosureTriangles[name].firstMatch
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication, fullScreen: Bool = false) {
        let screenshot = fullScreen ? XCUIScreen.main.screenshot() : app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
