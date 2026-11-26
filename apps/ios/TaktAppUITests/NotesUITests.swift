import XCTest

/// 悬浮按钮 menu, 笔记 list, first-recording intro and recording against the `-demo` backend, where recording,
/// transcription and diarization are faked (every recording becomes the 京都 conversation).
/// Screenshots are attached to the test results.
final class NotesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-demo"]
    }

    private func launch(theme: String? = nil) {
        if let theme { app.launchArguments += ["-theme", theme] }
        app.launch()
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 5))
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Waits out a push / pop before tapping.
    private func tapWhenHittable(_ e: XCUIElement) {
        let ready = NSPredicate { _, _ in e.exists && e.isHittable }
        wait(for: [expectation(for: ready, evaluatedWith: nil)], timeout: 5)
        e.tap()
    }

    private func openMenu() {
        tapWhenHittable(el("fab.menu"))
        XCTAssertTrue(el("menu.new").waitForExistence(timeout: 2))
    }

    /// 录音 from the home menu; the intro the first time.
    private func recordFromMenu(intro: Bool = true, autoOff: Bool = false) {
        openMenu()
        el("menu.record").tap()
        if intro {
            XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
            if autoOff {
                el("intro.auto").tap()
                XCTAssertEqual(el("intro.auto").value as? String, "0")
            }
            el("intro.start").tap()
        }
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
    }

    /// Stops; the notes list is underneath with the new note on top.
    private func stop() -> XCUIElement {
        tapWhenHittable(el("recording.stop"))
        XCTAssertTrue(el("recording.stop").waitForNonExistence(timeout: 3))
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))
        let row = newNote
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertLessThan(row.frame.minY, app.buttons["note.京都讨论"].frame.minY, "newest first")
        return row
    }

    /// The note recorded in this test (the demo seed is 京都讨论).
    private var newNote: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note.' AND identifier != 'note.京都讨论'")).firstMatch
    }

    func testMenuOpensAndCloses() {
        launch()
        XCTAssertFalse(el("menu.search").exists, "closed menu is not in the hierarchy")
        openMenu()
        for id in ["menu.search", "menu.notes", "menu.record", "menu.new"] {
            XCTAssertTrue(el(id).exists, id)
        }
        XCTAssertLessThan(el("menu.search").frame.minY, el("menu.new").frame.minY, "查找 on top, 新建 Project last")
        sleep(1)
        snap("menu open")
        el("fab.menu").tap()
        XCTAssertTrue(el("menu.search").waitForNonExistence(timeout: 2))

        // The backdrop closes it too.
        openMenu()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(el("menu.new").waitForNonExistence(timeout: 2))

        // 查找 and 笔记 push their screens; 返回 comes back.
        openMenu()
        el("menu.search").tap()
        XCTAssertTrue(app.textFields["查找"].waitForExistence(timeout: 3))
        // The simulator's first keyboard may show its swipe-typing intro over everything.
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 1) { intro.tap() }
        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
        openMenu()
        el("menu.notes").tap()
        XCTAssertTrue(app.buttons["note.京都讨论"].waitForExistence(timeout: 3))
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
    }

    func testFirstRecordShowsIntroThenRecords() {
        launch()
        openMenu()
        el("menu.record").tap()
        XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["录完自动整理成任务"].exists)
        XCTAssertEqual(el("intro.auto").value as? String, "1", "自动生成任务 starts on")
        sleep(1)
        snap("intro")
        el("intro.start").tap()
        XCTAssertTrue(el("intro.start").waitForNonExistence(timeout: 2), "closed sheet leaves the hierarchy")
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        XCTAssertEqual(el("recording.locale").value as? String, "中")
        sleep(2)
        snap("recording")
        _ = stop()
        snap("notes after recording")
    }

    func testSecondRecordSkipsIntro() {
        launch()
        recordFromMenu()
        _ = stop()
        el("notes.record").tap()
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        XCTAssertFalse(el("intro.start").exists, "the intro shows only once")
        el("recording.stop").tap()
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))

        // From the home menu too.
        app.buttons["返回"].tap()
        recordFromMenu(intro: false)
        el("recording.stop").tap()
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))
    }

    func testAutoExtractProducesChains() {
        launch()
        recordFromMenu()
        sleep(1)
        let row = stop()
        let counted = NSPredicate { _, _ in Int(row.value as? String ?? "") ?? 0 > 0 }
        wait(for: [expectation(for: counted, evaluatedWith: nil)], timeout: 10)
        sleep(1)
        snap("chain badge")
    }

    func testAutoOffLeavesExtractButton() {
        launch()
        recordFromMenu(autoOff: true)
        let row = stop()
        XCTAssertEqual(el("notes.auto").value as? String, "0", "the list's switch follows the intro")
        // Processed and on the server: the row's value goes from 处理中 to "" (no chains without 自动生成任务).
        let settled = NSPredicate { _, _ in (row.value as? String ?? "") == "" }
        wait(for: [expectation(for: settled, evaluatedWith: nil)], timeout: 10)
        row.tap()
        XCTAssertTrue(app.buttons["提取"].waitForExistence(timeout: 5))
        snap("note without draft")
    }

    func testSwipeDeleteNote() {
        launch()
        openMenu()
        el("menu.notes").tap()
        let row = app.buttons["note.京都讨论"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let delete = app.buttons["delete：京都讨论"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        sleep(1)
        snap("swiped")
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        sleep(1)
        snap("empty notes")
    }

    func testLocaleChipRemembersChoice() {
        launch()
        recordFromMenu()
        el("recording.locale").tap()
        let ja = el("locale.ja_JP")
        XCTAssertTrue(ja.waitForExistence(timeout: 2))
        sleep(1)
        snap("language sheet")
        ja.tap()
        XCTAssertTrue(ja.waitForNonExistence(timeout: 2))
        XCTAssertEqual(el("recording.locale").value as? String, "日")
        _ = stop()
        el("notes.record").tap()
        XCTAssertTrue(el("recording.locale").waitForExistence(timeout: 3))
        XCTAssertEqual(el("recording.locale").value as? String, "日", "the last language is the default")
        el("recording.stop").tap()
    }

    /// Screens for comparing with the canvas (Phone / PhoneDark).
    func testScreensDark() {
        launch(theme: "dark")
        openMenu()
        sleep(1)
        snap("dark · menu")
        el("menu.notes").tap()
        XCTAssertTrue(app.buttons["note.京都讨论"].waitForExistence(timeout: 3))
        sleep(1)
        snap("dark · notes")
        el("notes.record").tap()
        XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
        sleep(1)
        snap("dark · intro")
        el("intro.start").tap()
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        sleep(2)
        snap("dark · recording")
        el("recording.locale").tap()
        sleep(1)
        snap("dark · language sheet")
        el("locale.zh_CN").tap()
        XCTAssertTrue(el("locale.zh_CN").waitForNonExistence(timeout: 2))
        _ = stop()
        sleep(2)
        snap("dark · notes after recording")
    }
}
