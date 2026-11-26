import XCTest

/// 查找 from the home menu: Project / task / note hits, each opening where it points, and 返回 all the way back to
/// the search. Against the in-memory demo backend (日本旅行 and the 京都讨论 note).
final class SearchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-demo"]
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func tapWhenHittable(_ e: XCUIElement) {
        let ready = NSPredicate { _, _ in e.exists && e.isHittable }
        wait(for: [expectation(for: ready, evaluatedWith: nil)], timeout: 5)
        e.tap()
    }

    /// The 返回 of the screen on top (the covered search screen keeps its own in the tree, off to the left).
    private func back() {
        let top = NSPredicate { _, _ in
            self.app.buttons.matching(NSPredicate(format: "label == %@", "返回")).allElementsBoundByIndex.contains { $0.isHittable }
        }
        wait(for: [expectation(for: top, evaluatedWith: nil)], timeout: 5)
        app.buttons.matching(NSPredicate(format: "label == %@", "返回")).allElementsBoundByIndex.first { $0.isHittable }!.tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Home › ＋ › 查找, then types `q` into the field (which has the focus already).
    private func search(_ q: String, theme: String? = nil) -> XCUIElement {
        if let theme { app.launchArguments += ["-theme", theme] }
        app.launch()
        tapWhenHittable(el("fab.menu"))
        tapWhenHittable(el("menu.search"))
        let field = el("search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let focused = NSPredicate { _, _ in (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        wait(for: [expectation(for: focused, evaluatedWith: nil)], timeout: 3)
        field.typeText(q)
        return field
    }

    func testSearchOpensTaskLevel() {
        let field = search("环球")
        let hit = el("search.hit.日本环球影城")
        XCTAssertTrue(hit.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["日本旅行 › 大阪"].exists, "the task's path under it")
        XCTAssertTrue(app.staticTexts["任务"].exists)
        snap("results")
        tapWhenHittable(hit)

        // 大阪's level, with the row flashed; 返回 walks up to the first level, then back to the search.
        XCTAssertTrue(el("row.日本环球影城").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["大阪"].exists && app.staticTexts["日本旅行"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard went with the search")
        snap("level with flash")
        back()
        XCTAssertTrue(el("row.东京").waitForExistence(timeout: 3))
        back()
        XCTAssertTrue(hit.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "环球")
        back()
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
    }

    func testSearchOpensProject() {
        _ = search("日本")
        tapWhenHittable(el("search.hit.日本旅行"))
        XCTAssertTrue(app.buttons["进入 大阪，6 项"].waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(el("search.hit.日本旅行").waitForExistence(timeout: 3))
    }

    func testSearchOpensTranscriptLine() {
        _ = search("清水寺")
        let hit = el("search.hit.那就七点出发。之后去清水寺，中午在二年坂吃午饭。")
        XCTAssertTrue(hit.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["京都讨论 · 0:19"].exists, "note title and time")
        snap("transcript hit")
        tapWhenHittable(hit)

        // The note's transcript with the player paused on that line.
        XCTAssertTrue(app.staticTexts["0:19 / 0:50"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["播放"].exists, "paused")
        sleep(1)
        XCTAssertTrue(app.staticTexts["0:19 / 0:50"].exists, "still at the line")
        snap("note paused at line")
        tapWhenHittable(el("note.back"))
        XCTAssertTrue(hit.waitForExistence(timeout: 3))
    }

    func testNoResults() {
        _ = search("火星")
        XCTAssertTrue(app.staticTexts["无结果"].waitForExistence(timeout: 3))
        snap("none")
    }

    func testSearchScreensDark() {
        _ = search("大阪", theme: "dark")
        XCTAssertTrue(el("search.hit.大阪城天守阁").waitForExistence(timeout: 3))
        snap("dark · results")
    }
}
