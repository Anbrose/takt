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
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 2))

        app.buttons["新建"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("黑门市场")
        snap("new task form")
        app.buttons["添加"].tap()

        XCTAssertTrue(row("黑门市场").waitForExistence(timeout: 5))
        snap("after create")
    }
}

/// 地图: pins + dotted line, status, 重排 (demo data uses straight-line routes, so numbers are stable).
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
        XCTAssertTrue(staticText(containing: "多").waitForExistence(timeout: 3))
        snap("map · detour")
        let optimize = app.buttons["重排"]
        XCTAssertTrue(optimize.isHittable)
        optimize.tap()
        XCTAssertTrue(app.staticTexts["不绕路"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["保存"].exists, "重排 saves directly, no 取消/保存 bar")
        app.buttons["距离"].tap()
        XCTAssertTrue(staticText(containing: "km").waitForExistence(timeout: 2))
        snap("map · optimized · distance")
    }

    func testLiveMapKitRoutes() throws {
        try XCTSkipUnless(live, "needs TAKT_UITEST_SERVER")
        app.buttons["地图"].tap()
        XCTAssertTrue(app.staticTexts["起点"].waitForExistence(timeout: 5))
        sleep(8) // let MapKit ETAs arrive
        snap("live map · transit · time")
        app.buttons["自驾"].tap()
        sleep(6)
        snap("live map · drive")
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
