import XCTest

/// 调整从属关系 in the plan: drag a task into another (asks first), 移到「父任务」 at the top (no question), and
/// 返回 one level at a time. Against the in-memory demo backend.
final class NestingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-demo"]
    }

    private func launch(theme: String? = nil) {
        if let theme { app.launchArguments += ["-theme", theme] }
        app.launch()
        openTrip(app)
        tapWhenHittable(app.buttons["进入 大阪，6 项"])
        XCTAssertTrue(row("大阪城天守阁").waitForExistence(timeout: 5))
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func row(_ name: String) -> XCUIElement { el("row.\(name)") }

    private func visibleOrder(_ names: [String]) -> [String] {
        names.sorted { row($0).frame.minY < row($1).frame.minY }
    }

    private func tapWhenHittable(_ e: XCUIElement) {
        let ready = NSPredicate { _, _ in e.exists && e.isHittable }
        wait(for: [expectation(for: ready, evaluatedWith: nil)], timeout: 5)
        e.tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 大阪城天守阁 → 日本环球影城, confirmed.
    private func nestCastleIntoUSJ() {
        dragRow(app, "大阪城天守阁", into: "日本环球影城")
        XCTAssertTrue(el("confirm.nest").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["放入「日本环球影城」？"].exists)
        snap("confirm")
        el("confirm.nest").tap()
        // The moved row fades out (240 ms), then the target is outlined for 1.4 s.
        usleep(600_000)
        snap("flash")
        XCTAssertTrue(el("confirm.nest").waitForNonExistence(timeout: 2), "the closed question leaves the hierarchy")
        XCTAssertTrue(app.buttons["进入 日本环球影城，1 项"].waitForExistence(timeout: 3))
    }

    func testDragTaskIntoSibling() {
        launch()
        nestCastleIntoUSJ()
        XCTAssertTrue(row("大阪城天守阁").waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.buttons["保存"].exists, "moves save at once")
        XCTAssertEqual(visibleOrder(["日本环球影城", "道顿堀"]), ["日本环球影城", "道顿堀"])
        sleep(2)
        snap("after flash")

        // Saved: still there after going up and back in.
        tapWhenHittable(app.buttons["返回"])
        tapWhenHittable(app.buttons["进入 大阪，5 项"])
        XCTAssertTrue(app.buttons["进入 日本环球影城，1 项"].waitForExistence(timeout: 5))
    }

    func testCancelNestKeepsOrder() {
        launch()
        let names = ["大阪城天守阁", "日本环球影城", "道顿堀"]
        dragRow(app, "大阪城天守阁", into: "日本环球影城")
        XCTAssertTrue(el("confirm.nest").waitForExistence(timeout: 3))
        app.buttons["取消"].tap()
        XCTAssertTrue(el("confirm.nest").waitForNonExistence(timeout: 2))
        let back = expectation(for: NSPredicate { _, _ in self.visibleOrder(names) == names }, evaluatedWith: nil)
        wait(for: [back], timeout: 3)
        XCTAssertFalse(app.buttons["保存"].exists, "nothing to save")
        XCTAssertFalse(app.buttons["进入 日本环球影城，1 项"].exists)
        snap("after cancel")
    }

    func testPromoteFromChildLevel() {
        launch()
        XCTAssertFalse(el("up.zone").exists, "only while dragging")
        // The zone covers the top of the list (where 地图 is) once the drag starts.
        dragRow(app, "道顿堀", centreAt: app.buttons["地图"].frame.midY)
        XCTAssertFalse(el("confirm.nest").waitForExistence(timeout: 1), "移到上一级 doesn't ask")
        XCTAssertTrue(row("道顿堀").waitForNonExistence(timeout: 3))
        XCTAssertFalse(el("up.zone").exists, "gone with the drag")
        XCTAssertFalse(app.buttons["保存"].exists)

        // Right after 大阪 on the first level, which is up to date.
        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(app.buttons["进入 大阪，5 项"].waitForExistence(timeout: 3))
        XCTAssertTrue(row("道顿堀").waitForExistence(timeout: 3))
        let ys = ["大阪", "道顿堀", "东京", "北海道"].map { row($0).frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "道顿堀 sits between 大阪 and 东京")
        snap("promoted")
    }

    func testBackGoesUpOneLevel() {
        launch()
        nestCastleIntoUSJ()
        tapWhenHittable(app.buttons["进入 日本环球影城，1 项"])
        XCTAssertTrue(row("大阪城天守阁").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["大阪"].exists, "the parent's name above the title")
        snap("third level")

        // On the third level the zone offers 「大阪」; drop there and it lands right after 日本环球影城.
        dragRow(app, "大阪城天守阁", centreAt: app.buttons["地图"].frame.midY)
        XCTAssertTrue(row("大阪城天守阁").waitForNonExistence(timeout: 3))

        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(row("日本环球影城").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["日本旅行"].exists)
        XCTAssertEqual(visibleOrder(["日本环球影城", "大阪城天守阁", "道顿堀"]), ["日本环球影城", "大阪城天守阁", "道顿堀"])

        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(row("东京").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Project"].exists)
        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
    }

    func testNestingScreensDark() {
        launch(theme: "dark")
        nestCastleIntoUSJ()
    }
}
