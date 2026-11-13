import XCTest

/// End-to-end checks of 规划模式 in the simulator against the in-memory demo backend.
/// Screenshots are attached to the test results (Xcode: Report navigator → Attachments).
final class PlanFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // TAKT_UITEST_SERVER=<url> (pass as TEST_RUNNER_TAKT_UITEST_SERVER to xcodebuild) runs against
        // a real API server instead of the in-memory demo data. It mutates that server's data.
        if let server = ProcessInfo.processInfo.environment["TAKT_UITEST_SERVER"] {
            app.launchEnvironment["TAKT_API_URL"] = server
        } else {
            app.launchArguments = ["-demo"]
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
