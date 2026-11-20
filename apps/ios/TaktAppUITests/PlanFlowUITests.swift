import XCTest

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
    }

    private func row(_ name: String) -> XCUIElement { app.descendants(matching: .any)["row.\(name)"] }
    private func handle(_ name: String) -> XCUIElement { app.descendants(matching: .any)["handle.\(name)"] }

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

        handle("大阪城天守阁").press(
            forDuration: 0.2, thenDragTo: row("道顿堀"), withVelocity: .slow, thenHoldForDuration: 0.2)

        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertNotEqual(visibleOrder(names).first, "大阪城天守阁", "dragged row left the top")
        snap("after drag (unsaved)")

        app.buttons["取消"].tap()
        let restored = expectation(for: NSPredicate { _, _ in self.visibleOrder(names) == names }, evaluatedWith: nil)
        wait(for: [restored], timeout: 3)
    }

    func testDragThenSavePersistsAcrossNavigation() {
        enterOsaka()
        handle("大阪城天守阁").press(
            forDuration: 0.2, thenDragTo: row("道顿堀"), withVelocity: .slow, thenHoldForDuration: 0.2)
        app.buttons["保存"].tap()

        app.buttons["返回"].tap()
        enterOsaka()
        let names = ["大阪城天守阁", "日本环球影城", "道顿堀"]
        XCTAssertNotEqual(visibleOrder(names).first, "大阪城天守阁")
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
        XCTAssertTrue(app.buttons["进入 大阪，6 项"].waitForExistence(timeout: 5))
    }
}
