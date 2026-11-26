import XCTest

/// The app opens on the Project 列表; most tests start inside 日本旅行.
func openTrip(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let card = app.buttons["project.日本旅行"]
    XCTAssertTrue(card.waitForExistence(timeout: 5), "Project 列表 shows 日本旅行", file: file, line: line)
    card.tap()
    XCTAssertTrue(app.buttons["进入 大阪，6 项"].waitForExistence(timeout: 5), file: file, line: line)
}

/// Drags `name`'s handle so the dragged card's centre ends at `centreY` (screen points), then lets go.
/// The drop goes by that centre (`Order.dropTarget`): a row's middle band nests, its edges reorder.
func dragRow(_ app: XCUIApplication, _ name: String, centreAt centreY: CGFloat) {
    let row = app.descendants(matching: .any)["row.\(name)"]
    let handle = app.descendants(matching: .any)["handle.\(name)"]
    let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
    let end = CGPoint(x: start.x, y: start.y + centreY - row.frame.midY)
    let origin = app.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(
        forDuration: 0.2, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
}

/// Drags `name` onto the middle of `target` (→ 「放入「target」？」).
func dragRow(_ app: XCUIApplication, _ name: String, into target: String) {
    dragRow(app, name, centreAt: app.descendants(matching: .any)["row.\(target)"].frame.midY)
}

/// Drags `name` just above `target` (the gap before it: a reorder, not a nest).
func dragRow(_ app: XCUIApplication, _ name: String, above target: String) {
    dragRow(app, name, centreAt: app.descendants(matching: .any)["row.\(target)"].frame.minY - 5)
}

/// End-to-end checks of 规划模式 in the simulator against the in-memory demo backend.
/// Screenshots are attached to the test results (Xcode: Report navigator → Attachments).
final class PlanFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash"]
        // TAKT_UITEST_SERVER=<url> (pass as TEST_RUNNER_TAKT_UITEST_SERVER to xcodebuild) runs against
        // a real API server instead of the in-memory demo data. It mutates that server's data.
        if let server = ProcessInfo.processInfo.environment["TAKT_UITEST_SERVER"] {
            app.launchEnvironment["TAKT_API_URL"] = server
        } else {
            app.launchArguments.append("-demo")
        }
        app.launch()
        openTrip(app)
    }

    private func row(_ name: String) -> XCUIElement { app.descendants(matching: .any)["row.\(name)"] }

    /// Task names sorted by their on-screen position.
    private func visibleOrder(_ names: [String]) -> [String] {
        names.sorted { row($0).frame.minY < row($1).frame.minY }
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func enterOsaka() {
        let open = app.buttons["进入 大阪，6 项"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(row("大阪城天守阁").waitForExistence(timeout: 5))
    }

    func testNavigateIntoAStageAndBack() {
        enterOsaka()
        XCTAssertTrue(app.staticTexts["日本旅行"].exists, "overline shows the parent")
        snap("大阪 level")
        app.buttons["返回"].tap()
        XCTAssertTrue(row("东京").waitForExistence(timeout: 5))
    }

    func testDragThenCancelRestoresOrder() {
        enterOsaka()
        let names = ["大阪城天守阁", "日本环球影城", "道顿堀"]
        XCTAssertEqual(visibleOrder(names), names)

        dragRow(app, "道顿堀", above: "日本环球影城")

        let save = app.buttons["保存"]
        XCTAssertFalse(app.descendants(matching: .any)["confirm.nest"].exists, "an edge reorders, no 放入 question")
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertEqual(visibleOrder(names), ["大阪城天守阁", "道顿堀", "日本环球影城"], "dragged row went before 日本环球影城")
        snap("after drag (unsaved)")

        app.buttons["取消"].tap()
        let restored = expectation(for: NSPredicate { _, _ in self.visibleOrder(names) == names }, evaluatedWith: nil)
        wait(for: [restored], timeout: 3)
    }

    func testDragThenSavePersistsAcrossNavigation() {
        enterOsaka()
        dragRow(app, "道顿堀", above: "日本环球影城")
        app.buttons["保存"].tap()

        app.buttons["返回"].tap()
        enterOsaka()
        let names = ["大阪城天守阁", "日本环球影城", "道顿堀"]
        XCTAssertEqual(visibleOrder(names), ["大阪城天守阁", "道顿堀", "日本环球影城"])
        snap("saved order")
    }

    func testSelectAndCreate() {
        enterOsaka()
        app.buttons["勾选：道顿堀"].tap()
        XCTAssertTrue(app.buttons["取消勾选：道顿堀"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["全选"].exists, "全选 is gone")

        app.buttons["新建"].tap() // the floating +
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("黑门市场")
        snap("new task form")
        app.buttons["添加"].tap()

        XCTAssertTrue(row("黑门市场").waitForExistence(timeout: 5))
        snap("after create")
    }

    func testSwipeLeftToDelete() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TAKT_UITEST_SERVER"] != nil,
                      "demo-only: would delete the live server's data")
        enterOsaka()
        let delete = app.buttons["删除：道顿堀"]
        XCTAssertFalse(delete.exists, "hidden until swiped")
        row("道顿堀").swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        snap("swiped")
        row("海游馆").swipeLeft() // only one open at a time
        XCTAssertTrue(app.buttons["删除：海游馆"].waitForExistence(timeout: 2))
        row("海游馆").swipeRight()
        row("道顿堀").swipeLeft()
        app.buttons["删除：道顿堀"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row("道顿堀"))
        wait(for: [gone], timeout: 3)
        XCTAssertTrue(row("海游馆").exists)
        snap("after delete")
    }
}

/// 地图: pins + dashed legs, distance, 重排, Google 地图 (straight-line distances, so numbers are stable).
final class MapUITests: XCTestCase {
    private var app: XCUIApplication!
    private var live: Bool { ProcessInfo.processInfo.environment["TAKT_UITEST_SERVER"] != nil }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash"]
        if let server = ProcessInfo.processInfo.environment["TAKT_UITEST_SERVER"] {
            app.launchEnvironment["TAKT_API_URL"] = server
        } else {
            app.launchArguments.append("-demo")
        }
        app.launch()
        openTrip(app)
        let open = app.buttons["进入 大阪，6 项"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["地图"].waitForExistence(timeout: 5))
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func staticText(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testMapShowsDetourAndOptimizeFixesIt() throws {
        try XCTSkipIf(live, "demo-only: 重排 would reorder the live server's data")
        app.buttons["地图"].tap()
        XCTAssertTrue(app.staticTexts["起点"].waitForExistence(timeout: 3), "rows compress and show legs")
        XCTAssertTrue(app.staticTexts["36.1 km"].waitForExistence(timeout: 3), "only the distance, no status words")
        XCTAssertFalse(app.buttons["公交"].exists, "no 出行方式 picker any more")
        XCTAssertTrue(app.links["Google 地图"].exists || app.buttons["Google 地图"].exists)
        snap("map · detour")
        let optimize = app.buttons["重排"]
        XCTAssertTrue(optimize.isHittable)
        optimize.tap()
        let hidden = expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: optimize)
        wait(for: [hidden], timeout: 3)
        XCTAssertFalse(app.buttons["保存"].exists, "重排 saves directly, no 取消/保存 bar")
        XCTAssertTrue(staticText(containing: "km").exists)
        snap("map · optimized")
    }

    func testTapAPinHighlightsItsLegs() {
        app.buttons["地图"].tap()
        let pin = app.buttons["3 道顿堀"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        snap("map · focus 3")
        pin.tap()
        snap("map · whole route again")
    }
}

/// The splash itself (first launch: 重播 / 开始).
final class SplashUITests: XCTestCase {
    func testFirstLaunchSplashThenStart() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-splash.seen", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["TAKT，规划每一步"].waitForExistence(timeout: 3)
            || app.otherElements["TAKT，规划每一步"].exists)
        let start = app.buttons["开始"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "splash end"
        shot.lifetime = .keepAlways
        add(shot)
        start.tap()
        openTrip(app)
    }
}

/// Project 列表: create → lands inside, back → list, rename and delete via the long-press menu.
final class ProjectListUITests: XCTestCase {
    func testCreateRenameDeleteAndBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-demo"]
        app.launch()

        let trip = app.buttons["project.日本旅行"]
        XCTAssertTrue(trip.waitForExistence(timeout: 5))

        // ＋ → 新建 Project → pushes into the new (empty) project.
        app.descendants(matching: .any)["fab.menu"].tap()
        let new = app.descendants(matching: .any)["menu.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 2))
        new.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("搬家")
        app.buttons["创建"].tap()
        XCTAssertTrue(app.staticTexts["搬家"].waitForExistence(timeout: 5))
        let back = app.buttons["返回"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        snap(app, "inside new project")

        // 返回 at the top level → back on the list, newest first.
        back.tap()
        let moving = app.buttons["project.搬家"]
        XCTAssertTrue(moving.waitForExistence(timeout: 5))
        XCTAssertTrue(trip.waitForExistence(timeout: 2))
        XCTAssertLessThan(moving.frame.minY, trip.frame.minY)

        // Long-press → 重命名.
        moving.press(forDuration: 1.0)
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()
        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        XCTAssertEqual(renameField.value as? String, "搬家")
        renameField.tap()
        renameField.typeText("2")
        app.buttons["保存"].tap()
        let renamed = app.buttons["project.搬家2"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        snap(app, "renamed")

        // Long-press → 删除 → confirm.
        renamed.press(forDuration: 1.0)
        let delete = app.buttons["删除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let alert = app.alerts["删除「搬家2」？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["删除"].tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 5))
        XCTAssertTrue(trip.exists)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
